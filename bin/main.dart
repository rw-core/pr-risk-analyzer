import 'dart:convert';
import 'dart:io';
import 'package:pr_risk_analyzer/src/github.dart';
import 'package:rw_git/rw_git.dart';

Future<void> main() async {
  final env = Platform.environment;

  final token = env['INPUT_GITHUB_TOKEN'] ?? '';
  final workingDirectory = env['INPUT_WORKING_DIRECTORY'] ?? '.';
  final volatilityThresholdStr = env['INPUT_VOLATILITY_THRESHOLD'] ?? '20.0';
  final failOnWarningStr = env['INPUT_FAIL_ON_WARNING'] ?? 'false';

  final volatilityThreshold = double.tryParse(volatilityThresholdStr) ?? 20.0;
  final failOnWarning = failOnWarningStr.toLowerCase() == 'true';

  final eventPath = env['GITHUB_EVENT_PATH'];
  final shas = GitHub.readPrShas(eventPath);

  if (shas == null) {
    stderr.writeln(
      'pr-risk-analyzer: not a pull_request event; nothing to analyse.',
    );
    return;
  }

  final prBaseSha = shas.base;
  final prHeadSha = shas.head;
  final revisionRange = '$prBaseSha..$prHeadSha';

  final repositoryPath = Directory(workingDirectory).absolute.path;
  final runner = ProcessRunner.defaultRunner();

  // --- DETERMINE HISTORY WINDOW ---
  // Every history-scanning algorithm below is bounded to the 2 years
  // preceding the PR's base commit (the last commit before the PR's own
  // commits), not "today" — so re-running CI later on a stale/unmerged PR
  // still analyses the same, stable window instead of drifting forward.
  stdout.writeln('Resolving history window...');
  final baseDateRes = await runner.run('git', [
    'log',
    '-1',
    '--format=%aI',
    prBaseSha,
  ], workingDirectory: repositoryPath);
  if (baseDateRes.exitCode != 0) {
    stderr.writeln(
      'pr-risk-analyzer: failed to resolve base commit date: '
      '${baseDateRes.stderr}',
    );
    exitCode = 1;
    return;
  }
  final baseDate = GitDateTime.parse(
    (baseDateRes.stdout?.toString() ?? '').trim(),
  ).utc;
  final historySince = DateTime.utc(
    baseDate.year - 2,
    baseDate.month,
    baseDate.day,
    baseDate.hour,
    baseDate.minute,
    baseDate.second,
  );
  final historySinceIso = historySince.toIso8601String();
  final historyRangeLabel =
      '${historySince.toIso8601String().split('T').first} - '
      '${baseDate.toIso8601String().split('T').first}';

  // --- GET MODIFIED FILES ---
  stdout.writeln('Fetching PR modified files...');
  final diffRes = await runner.run('git', [
    'diff',
    '--name-only',
    prBaseSha,
    prHeadSha,
  ], workingDirectory: repositoryPath);
  if (diffRes.exitCode != 0) {
    stderr.writeln(
      'pr-risk-analyzer: failed to run git diff: ${diffRes.stderr}',
    );
    exitCode = 1;
    return;
  }

  final modifiedFiles = (diffRes.stdout?.toString() ?? '')
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();

  if (modifiedFiles.isEmpty) {
    stdout.writeln('No modified files found in PR. Exiting.');
    GitHub.writeOutputs({
      'bug-hotspots-count': '0',
      'volatile-files-count': '0',
      'bus-factor-score': '0',
      'tribal-knowledge-count': '0',
      'too-many-cooks-count': '0',
      'departure-defect-count': '0',
      'defect-injection-count': '0',
      'clean-up-exception-count': '0',
    });
    GitHub.writeStepSummary('✅ No files modified in this PR.');
    return;
  }

  // Every count defaults to '0' so a mid-run failure still yields a complete
  // (rather than truncated) set of action outputs.
  final outputs = <String, String>{
    'bug-hotspots-count': '0',
    'volatile-files-count': '0',
    'bus-factor-score': '0',
    'tribal-knowledge-count': '0',
    'too-many-cooks-count': '0',
    'departure-defect-count': '0',
    'defect-injection-count': '0',
    'clean-up-exception-count': '0',
  };

  var hasWarnings = false;
  final findings = StringBuffer();
  final reference = StringBuffer();
  Object? failure;
  StackTrace? failureStackTrace;

  try {
    // --- BUG HOTSPOTS WARNING ---
    stdout.writeln('Running Bug Hotspots Check...');
    final szz = SzzAlgorithm(runner);
    final bugHotspots = await szz.execute(
      repositoryPath,
      targetFiles: modifiedFiles,
      since: historySinceIso,
    );

    // --- CHURN HEURISTIC ---
    stdout.writeln('Running PR Churn Check...');
    final churn = ChurnHeuristic(runner);
    final churnMetrics = await churn.calculateChurnWithAuthors(
      repositoryPath,
      revisionRange: revisionRange,
    );

    // --- CODE VOLATILITY WARNING ---
    stdout.writeln('Running Code Volatility Check...');
    final volatility = CodeVolatilityAlgorithm(runner);
    final volatileFiles = await volatility.execute(
      repositoryPath,
      targetFiles: modifiedFiles,
      since: historySinceIso,
    );

    // Filter volatile files by threshold
    final highlyVolatileFiles = volatileFiles
        .where((v) => v.volatilityScore > volatilityThreshold)
        .toList();

    // --- BUS FACTOR ANALYSIS ---
    stdout.writeln('Running Bus Factor Analysis...');
    final busFactorAlgorithm = BusFactorAlgorithm(runner);
    final busFactorResult = await busFactorAlgorithm.executeForFiles(
      repositoryPath,
      modifiedFiles,
      since: historySinceIso,
    );

    final busFactorScores = <String, dynamic>{};
    for (final entry in busFactorResult.entries) {
      busFactorScores[entry.key] = {
        'busFactor': entry.value.busFactor,
        'totalDevelopers': entry.value.totalDevelopers,
        'topContributors': entry.value.topContributors
            .map(
              (c) => {
                'author': c.author,
                'contributions': c.contributions,
                'percentage': c.percentage,
              },
            )
            .toList(),
      };
    }

    outputs['bug-hotspots-count'] = '${bugHotspots.length}';
    outputs['volatile-files-count'] = '${highlyVolatileFiles.length}';
    outputs['bus-factor-score'] = jsonEncode(busFactorScores);

    // --- COMPOUND RISKS ANALYSIS ---
    stdout.writeln(
      'Fetching historical churn, code quality, and refactorings for compound risks...',
    );
    final historicalChurn = await ChurnHeuristic(
      runner,
    ).calculateChurnWithAuthors(repositoryPath, since: historySinceIso);
    final codeQuality = await AdvancedMetricsHeuristic(
      runner,
    ).calculateAdvancedMetrics(repositoryPath, since: historySinceIso);
    final recentRefactorings = await RefactoringDetectionAlgorithm(
      runner,
    ).execute(repositoryPath, since: historySinceIso);

    final bugHotspotFiles = bugHotspots.map((m) => m.filePath).toSet();
    final highlyVolatileFileNames = highlyVolatileFiles
        .map((v) => v.filePath)
        .toSet();

    final refactoredFiles = <String>{};
    for (final ref in recentRefactorings) {
      for (final renamed in ref.renamedFiles) {
        refactoredFiles.add(renamed);
        if (renamed.contains(' -> ')) {
          final parts = renamed.split(' -> ');
          if (parts.length == 2) {
            refactoredFiles.add(parts[1].trim());
          }
        }
      }
    }

    final fileChurnList = historicalChurn.fileChurn.values.toList()
      ..sort((a, b) => a.total.compareTo(b.total));
    final fileComplexityList = codeQuality.fileComplexity.values.toList()
      ..sort();

    double getChurnPercentile(int total) {
      if (fileChurnList.isEmpty) return 0.0;
      final index = fileChurnList.indexWhere((c) => c.total >= total);
      return index < 0 ? 1.0 : index / fileChurnList.length;
    }

    double getComplexityPercentile(int complexity) {
      if (fileComplexityList.isEmpty) return 0.0;
      final index = fileComplexityList.indexWhere((c) => c >= complexity);
      return index < 0 ? 1.0 : index / fileComplexityList.length;
    }

    final tribalKnowledgeFiles = <String>[];
    final tooManyCooksFiles = <String>[];
    final defectInjectionFiles = <String>[];
    final cleanUpExceptionFiles = <String>[];
    final singleOwnerFiles = <String, List<String>>{};

    for (final file in modifiedFiles) {
      final fileChurn = historicalChurn.fileChurn[file];
      final totalCommits = fileChurn?.total ?? 0;
      final authorsMap = fileChurn?.authors ?? {};

      bool hasSingleOwner = false;
      bool hasTooManyCooks = false;
      String? singleOwner;

      if (totalCommits > 0) {
        int minorContributors = 0;
        for (final entry in authorsMap.entries) {
          final percentage = entry.value / totalCommits;
          if (percentage > 0.5) {
            hasSingleOwner = true;
            singleOwner = entry.key;
          }
          if (percentage < 0.05) minorContributors++;
        }
        if (minorContributors >= 3) hasTooManyCooks = true;
      }

      final isHotspot = bugHotspotFiles.contains(file);
      final isVolatile = highlyVolatileFileNames.contains(file);
      final complexity = codeQuality.fileComplexity[file] ?? 0;

      if (isHotspot && hasSingleOwner) {
        tribalKnowledgeFiles.add(file);
        if (singleOwner != null) {
          singleOwnerFiles.putIfAbsent(singleOwner, () => []).add(file);
        }
      }

      if (isHotspot && hasTooManyCooks) {
        tooManyCooksFiles.add(file);
      }

      if (isVolatile || (fileChurn != null && fileChurn.total > 10)) {
        final churnPerc = getChurnPercentile(totalCommits);
        final compPerc = getComplexityPercentile(complexity);
        if (churnPerc * compPerc > 0.25) {
          defectInjectionFiles.add(file);
        }
      }

      if (isVolatile || (fileChurn != null && fileChurn.total > 10)) {
        if (refactoredFiles.contains(file)) {
          cleanUpExceptionFiles.add(file);
        }
      }
    }

    final departureDefectAuthors = singleOwnerFiles.entries
        .where((e) => e.value.length >= 2)
        .toList();

    outputs['tribal-knowledge-count'] = '${tribalKnowledgeFiles.length}';
    outputs['too-many-cooks-count'] = '${tooManyCooksFiles.length}';
    outputs['departure-defect-count'] = '${departureDefectAuthors.length}';
    outputs['defect-injection-count'] = '${defectInjectionFiles.length}';
    outputs['clean-up-exception-count'] = '${cleanUpExceptionFiles.length}';

    // --- REPORT GENERATION ---
    // Findings are surfaced first so reviewers see the actionable results
    // immediately; the methodology/citations backing each finding are moved
    // to a "References" section at the bottom.
    hasWarnings = bugHotspots.isNotEmpty || highlyVolatileFiles.isNotEmpty;

    final hasCompoundRisks =
        tribalKnowledgeFiles.isNotEmpty ||
        tooManyCooksFiles.isNotEmpty ||
        departureDefectAuthors.isNotEmpty ||
        defectInjectionFiles.isNotEmpty ||
        cleanUpExceptionFiles.isNotEmpty;

    if (hasCompoundRisks) {
      findings.writeln('### 🎯 Compound PR Risks');

      if (tribalKnowledgeFiles.isNotEmpty) {
        findings.writeln('**🔴 Tribal Knowledge Risk**');
        for (final f in tribalKnowledgeFiles) {
          findings.writeln('- **`$f`**');
        }
        findings.writeln('');
      }

      if (tooManyCooksFiles.isNotEmpty) {
        findings.writeln('**🟠 Too Many Cooks Risk**');
        for (final f in tooManyCooksFiles) {
          findings.writeln('- **`$f`**');
        }
        findings.writeln('');
      }

      if (departureDefectAuthors.isNotEmpty) {
        findings.writeln('**🔴 Departure Defect Risk**');
        for (final entry in departureDefectAuthors) {
          findings.writeln(
            '- **`${entry.key}`** owns ${entry.value.length} hotspot files:',
          );
          for (final f in entry.value) {
            findings.writeln('  - `$f`');
          }
        }
        findings.writeln('');
      }

      if (defectInjectionFiles.isNotEmpty) {
        findings.writeln(
          '**🔴 Defect-Injection Predictor (Refactoring Targets)**',
        );
        for (final f in defectInjectionFiles) {
          findings.writeln('- **`$f`**');
        }
        findings.writeln('');
      }

      if (cleanUpExceptionFiles.isNotEmpty) {
        findings.writeln('**🟢 Clean-up Exception**');
        for (final f in cleanUpExceptionFiles) {
          findings.writeln(
            '- **`$f`** (Volatility warnings can be downgraded)',
          );
        }
        findings.writeln('');
      }

      reference.writeln('### 🎯 Compound PR Risks');
      reference.writeln(
        'Actionable compound findings identified by combining multiple risk vectors.\n',
      );
      reference.writeln('**🔴 Tribal Knowledge Risk**');
      reference.writeln(
        '- **Condition**: A bug hotspot file is owned by a single author (Bus factor > 50%).',
      );
      reference.writeln(
        '- **Rationale**: Undocumented tribal knowledge in bug-prone code increases the risk of injecting defects if the context is siloed.',
      );
      reference.writeln(
        '- **Citation**: Avelino et al. (2016) - Knowledge loss and defect proneness.\n',
      );
      reference.writeln('**🟠 Too Many Cooks Risk**');
      reference.writeln(
        '- **Condition**: A bug hotspot file has three or more minor contributors (< 5% ownership).',
      );
      reference.writeln(
        '- **Rationale**: The count of minor contributors is an even stronger defect predictor than ownership concentration itself.',
      );
      reference.writeln(
        '- **Citation**: Bird et al. (FSE 2011) - Don\'t touch my code: examining the effects of ownership on software quality.\n',
      );
      reference.writeln('**🔴 Departure Defect Risk**');
      reference.writeln(
        '- **Condition**: A single author solely owns two or more single-owner bug-hotspot files.',
      );
      reference.writeln(
        '- **Rationale**: The departure of this specific developer would orphan the most defect-prone code in the repository.',
      );
      reference.writeln(
        '- **Citation**: Mockus & Herbsleb (2002); Avelino et al. (2016).\n',
      );
      reference.writeln(
        '**🔴 Defect-Injection Predictor (Refactoring Targets)**',
      );
      reference.writeln(
        '- **Condition**: High churn combined with a high complexity outlier on the same file (product > 0.25).',
      );
      reference.writeln(
        '- **Rationale**: Actively-changing complex code is the prime defect-injection risk. These are prime refactoring targets.',
      );
      reference.writeln(
        '- **Citation**: Nagappan & Ball (2005); Tornhill (2015) - Prioritizing tech debt in the PR.\n',
      );
      reference.writeln('**🟢 Clean-up Exception**');
      reference.writeln(
        '- **Condition**: High volatility/churn on files modified by detected refactorings.',
      );
      reference.writeln(
        '- **Rationale**: High churn explained by clean-up and refactoring carries a demonstrably lower defect risk.',
      );
      reference.writeln(
        '- **Citation**: Neto et al. (SANER 2018) - The Impact of Refactoring Changes on the SZZ Algorithm.\n',
      );
    }

    if (!hasWarnings) {
      findings.writeln(
        '✅ No bug hotspots or highly volatile files detected in this PR.',
      );
    } else {
      if (bugHotspots.isNotEmpty) {
        findings.writeln('### ⚠️ Bug Hotspots Detected');
        for (final match in bugHotspots) {
          findings.writeln(
            '- **`${match.introducingCommitHash}`**: Fixed in `${match.fixingCommitHash}` (File: `${match.filePath}`)',
          );
        }
        findings.writeln('');

        reference.writeln('### ⚠️ Bug Hotspots Detected');
        reference.writeln(
          'This PR modifies files with a history of bug fixes. Reviewers should be extra cautious.',
        );
        reference.writeln(
          '> **Citation & Explanation**: *Śliwerski, Zimmermann, and Zeller (2005) - SZZ Algorithm.* Files that frequently required fixes in the past are highly likely to contain future bugs.\n',
        );
      }

      if (highlyVolatileFiles.isNotEmpty) {
        findings.writeln('### ⚠️ Highly Volatile Files Detected');
        for (final v in highlyVolatileFiles) {
          findings.writeln('- **`${v.filePath}`**');
          findings.writeln('  - Historical changes: ${v.totalChanges}');
          findings.writeln('  - Unique authors: ${v.uniqueAuthors}');
          findings.writeln(
            '  - Volatility Score: ${v.volatilityScore.toStringAsFixed(2)}',
          );
        }
        findings.writeln('');

        reference.writeln('### ⚠️ Highly Volatile Files Detected');
        reference.writeln(
          'This PR modifies highly volatile files (constantly rewritten/churned). '
          'Consider looking for deeper architectural or structural issues.',
        );
        reference.writeln(
          '> **Citation & Explanation**: *Nagappan & Ball (2005).* High relative code churn implies active, unstable code that correlates strongly with defect density.\n',
        );
      }
    }

    findings.writeln('### PR Churn Metrics');
    findings.writeln('Total PR Commits: ${churnMetrics.totalCommits}');
    for (final fileChurn in churnMetrics.fileChurn.entries) {
      findings.writeln(
        '- **`${fileChurn.key}`**: ${fileChurn.value.total} changes by ${fileChurn.value.authors.length} authors in this PR.',
      );
    }
    findings.writeln('');

    reference.writeln('### PR Churn Metrics');
    reference.writeln(
      '> **Citation & Explanation**: *Nagappan & Ball (2005).* The raw number of commits and authors modifying a file within the PR scope.\n',
    );

    findings.writeln('### PR Files Bus Factor');
    if (busFactorResult.isEmpty) {
      findings.writeln('No bus factor data available for the modified files.');
    } else {
      for (final entry in busFactorResult.entries) {
        final file = entry.key;
        final bf = entry.value;
        if (bf.totalDevelopers == 0) {
          findings.writeln('- **`$file`**: Not enough history.');
        } else {
          findings.writeln(
            '- **`$file`**: Bus Factor **${bf.busFactor}** (out of ${bf.totalDevelopers} developers)',
          );
          for (final contributor in bf.topContributors) {
            final percentage = (contributor.percentage * 100).toStringAsFixed(
              1,
            );
            findings.writeln(
              '  - `${contributor.author}`: ${contributor.contributions} commits ($percentage%)',
            );
          }
        }
      }
    }
    findings.writeln('');

    reference.writeln('### PR Files Bus Factor');
    reference.writeln(
      '> **Citation & Explanation**: *Avelino et al. (2016).* A measure of knowledge concentration. A low bus factor indicates key developers hold critical, undocumented project knowledge.',
    );
  } catch (e, st) {
    failure = e;
    failureStackTrace = st;
    stderr.writeln(
      'pr-risk-analyzer: analysis failed partway through: $e\n$st',
    );
  }

  GitHub.writeOutputs(outputs);

  final reportSb = StringBuffer();
  reportSb.writeln('## PR Risk Analyzer Report');
  reportSb.writeln(
    '**History window scanned**: `$historyRangeLabel` '
    '(2 years of history preceding base commit `${prBaseSha.substring(0, 7)}`)',
  );
  reportSb.writeln('');
  if (failure != null) {
    reportSb.writeln(
      '> ⚠️ **Analysis did not complete successfully — results below are '
      'partial.** Error: `$failure`',
    );
    reportSb.writeln('');
  }
  reportSb.write(findings.toString());
  if (reference.isNotEmpty) {
    reportSb.writeln('---');
    reportSb.writeln('## References & Methodology');
    reportSb.write(reference.toString());
  }

  final reportMarkdown = reportSb.toString();
  GitHub.writeStepSummary(reportMarkdown);

  if ((hasWarnings || failure != null) && token.isNotEmpty) {
    final number = GitHub.prNumber(eventPath);
    final repository = env['GITHUB_REPOSITORY'];
    if (number != null && repository != null) {
      final gh = GitHub(token: token, repository: repository);
      try {
        await gh.upsertStickyComment(number, reportMarkdown);
      } catch (e) {
        stderr.writeln('pr-risk-analyzer: failed to post comment: $e');
      } finally {
        gh.close();
      }
    }
  }

  if (failure != null) {
    Error.throwWithStackTrace(failure, failureStackTrace!);
  }

  if (failOnWarning && hasWarnings) {
    stderr.writeln('pr-risk-analyzer: failing due to warnings found.');
    exitCode = 1;
  }
}
