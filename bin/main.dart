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
    stderr.writeln('pr-risk-analyzer: not a pull_request event; nothing to analyse.');
    return;
  }

  final prBaseSha = shas.base;
  final prHeadSha = shas.head;
  final revisionRange = '$prBaseSha..$prHeadSha';

  final repositoryPath = Directory(workingDirectory).absolute.path;
  final runner = ProcessRunner.defaultRunner();

  // --- GET MODIFIED FILES ---
  stdout.writeln('Fetching PR modified files...');
  final diffRes = await runner.run('git', ['diff', '--name-only', prBaseSha, prHeadSha], workingDirectory: repositoryPath);
  if (diffRes.exitCode != 0) {
    stderr.writeln('pr-risk-analyzer: failed to run git diff: ${diffRes.stderr}');
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

  // --- BUG HOTSPOTS WARNING ---
  stdout.writeln('Running Bug Hotspots Check...');
  final szz = SzzAlgorithm(runner);
  final bugHotspots = await szz.execute(
    repositoryPath,
    targetFiles: modifiedFiles,
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
  );

  // Filter volatile files by threshold
  final highlyVolatileFiles = volatileFiles
      .where((v) => v.volatilityScore > volatilityThreshold)
      .toList();

  // --- BUS FACTOR ANALYSIS ---
  stdout.writeln('Running Bus Factor Analysis...');
  final busFactorAlgorithm = BusFactorAlgorithm(runner);
  final busFactorResult = await busFactorAlgorithm.execute(repositoryPath);

  GitHub.writeOutputs({
    'bug-hotspots-count': '${bugHotspots.length}',
    'volatile-files-count': '${highlyVolatileFiles.length}',
    'bus-factor-score': '${busFactorResult.busFactor}',
  });

  // --- COMPOUND RISKS ANALYSIS ---
  stdout.writeln('Fetching historical churn, code quality, and refactorings for compound risks...');
  final historicalChurn = await ChurnHeuristic(runner).calculateChurnWithAuthors(repositoryPath, since: '1.year.ago');
  final codeQuality = await AdvancedMetricsHeuristic(runner).calculateAdvancedMetrics(repositoryPath);
  final recentRefactorings = await RefactoringDetectionAlgorithm(runner).execute(repositoryPath);

  final bugHotspotFiles = bugHotspots.map((m) => m.filePath).toSet();
  final highlyVolatileFileNames = highlyVolatileFiles.map((v) => v.filePath).toSet();

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

  final fileChurnList = historicalChurn.fileChurn.values.toList()..sort((a, b) => a.total.compareTo(b.total));
  final fileComplexityList = codeQuality.fileComplexity.values.toList()..sort();
  
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

  final departureDefectAuthors = singleOwnerFiles.entries.where((e) => e.value.length >= 2).toList();

  GitHub.writeOutputs({
    'tribal-knowledge-count': '${tribalKnowledgeFiles.length}',
    'too-many-cooks-count': '${tooManyCooksFiles.length}',
    'departure-defect-count': '${departureDefectAuthors.length}',
    'defect-injection-count': '${defectInjectionFiles.length}',
    'clean-up-exception-count': '${cleanUpExceptionFiles.length}',
  });

  // --- REPORT GENERATION ---
  final sb = StringBuffer();
  
  final hasCompoundRisks = tribalKnowledgeFiles.isNotEmpty || tooManyCooksFiles.isNotEmpty || departureDefectAuthors.isNotEmpty || defectInjectionFiles.isNotEmpty || cleanUpExceptionFiles.isNotEmpty;
  if (hasCompoundRisks) {
    sb.writeln('## 🎯 Compound PR Risks');
    sb.writeln('Actionable compound findings identified by combining multiple risk vectors:\n');
    
    if (tribalKnowledgeFiles.isNotEmpty) {
      sb.writeln('### 🔴 Tribal Knowledge Risk');
      sb.writeln('**Condition**: A bug hotspot file is owned by a single author (Bus factor > 50%).');
      sb.writeln('**Rationale**: Undocumented tribal knowledge in bug-prone code increases the risk of injecting defects if the context is siloed.');
      sb.writeln('> **Citation**: Avelino et al. (2016) - Knowledge loss and defect proneness.');
      for (final f in tribalKnowledgeFiles) {
        sb.writeln('- **`$f`**');
      }
      sb.writeln('');
    }

    if (tooManyCooksFiles.isNotEmpty) {
      sb.writeln('### 🟠 Too Many Cooks Risk');
      sb.writeln('**Condition**: A bug hotspot file has three or more minor contributors (< 5% ownership).');
      sb.writeln('**Rationale**: The count of minor contributors is an even stronger defect predictor than ownership concentration itself.');
      sb.writeln('> **Citation**: Bird et al. (FSE 2011) - Don\'t touch my code: examining the effects of ownership on software quality.');
      for (final f in tooManyCooksFiles) {
        sb.writeln('- **`$f`**');
      }
      sb.writeln('');
    }

    if (departureDefectAuthors.isNotEmpty) {
      sb.writeln('### 🔴 Departure Defect Risk');
      sb.writeln('**Condition**: A single author solely owns two or more single-owner bug-hotspot files.');
      sb.writeln('**Rationale**: The departure of this specific developer would orphan the most defect-prone code in the repository.');
      sb.writeln('> **Citation**: Mockus & Herbsleb (2002); Avelino et al. (2016).');
      for (final entry in departureDefectAuthors) {
        sb.writeln('- **`${entry.key}`** owns ${entry.value.length} hotspot files:');
        for (final f in entry.value) {
          sb.writeln('  - `$f`');
        }
      }
      sb.writeln('');
    }

    if (defectInjectionFiles.isNotEmpty) {
      sb.writeln('### 🔴 Defect-Injection Predictor (Refactoring Targets)');
      sb.writeln('**Condition**: High churn combined with a high complexity outlier on the same file (product > 0.25).');
      sb.writeln('**Rationale**: Actively-changing complex code is the prime defect-injection risk. These are prime refactoring targets.');
      sb.writeln('> **Citation**: Nagappan & Ball (2005); Tornhill (2015) - Prioritizing tech debt in the PR.');
      for (final f in defectInjectionFiles) {
        sb.writeln('- **`$f`**');
      }
      sb.writeln('');
    }

    if (cleanUpExceptionFiles.isNotEmpty) {
      sb.writeln('### 🟢 Clean-up Exception');
      sb.writeln('**Condition**: High volatility/churn on files modified by detected refactorings.');
      sb.writeln('**Rationale**: High churn explained by clean-up and refactoring carries a demonstrably lower defect risk.');
      sb.writeln('> **Citation**: Neto et al. (SANER 2018) - The Impact of Refactoring Changes on the SZZ Algorithm.');
      for (final f in cleanUpExceptionFiles) {
        sb.writeln('- **`$f`** (Volatility warnings can be downgraded)');
      }
      sb.writeln('');
    }
  }

  sb.writeln('## PR Risk Analyzer Report');

  final hasWarnings = bugHotspots.isNotEmpty || highlyVolatileFiles.isNotEmpty;

  if (!hasWarnings) {
    sb.writeln('✅ No bug hotspots or highly volatile files detected in this PR.');
  } else {
    if (bugHotspots.isNotEmpty) {
      sb.writeln('### ⚠️ Bug Hotspots Detected');
      sb.writeln('This PR modifies files with a history of bug fixes. Reviewers should be extra cautious.');
      sb.writeln('> **Citation & Explanation**: *Śliwerski, Zimmermann, and Zeller (2005) - SZZ Algorithm.* Files that frequently required fixes in the past are highly likely to contain future bugs.');
      for (final match in bugHotspots) {
        sb.writeln('- **`${match.introducingCommitHash}`**: Fixed in `${match.fixingCommitHash}` (File: `${match.filePath}`)');
      }
      sb.writeln('');
    }

    if (highlyVolatileFiles.isNotEmpty) {
      sb.writeln('### ⚠️ Highly Volatile Files Detected');
      sb.writeln('This PR modifies highly volatile files (constantly rewritten/churned).');
      sb.writeln('Consider looking for deeper architectural or structural issues.');
      sb.writeln('> **Citation & Explanation**: *Nagappan & Ball (2005).* High relative code churn implies active, unstable code that correlates strongly with defect density.');
      for (final v in highlyVolatileFiles) {
        sb.writeln('- **`${v.filePath}`**');
        sb.writeln('  - Historical changes: ${v.totalChanges}');
        sb.writeln('  - Unique authors: ${v.uniqueAuthors}');
        sb.writeln('  - Volatility Score: ${v.volatilityScore.toStringAsFixed(2)}');
      }
      sb.writeln('');
    }
  }

  sb.writeln('### PR Churn Metrics');
  sb.writeln('> **Citation & Explanation**: *Nagappan & Ball (2005).* The raw number of commits and authors modifying a file within the PR scope.');
  sb.writeln('Total PR Commits: ${churnMetrics.totalCommits}');
  for (final fileChurn in churnMetrics.fileChurn.entries) {
    sb.writeln('- **`${fileChurn.key}`**: ${fileChurn.value.total} changes by ${fileChurn.value.authors.length} authors in this PR.');
  }

  sb.writeln('');
  sb.writeln('### Repository Bus Factor');
  sb.writeln('> **Citation & Explanation**: *Avelino et al. (2016).* A measure of knowledge concentration. A low bus factor indicates key developers hold critical, undocumented project knowledge.');
  sb.writeln('The repository Bus Factor is **${busFactorResult.busFactor}** (out of ${busFactorResult.totalDevelopers} total developers).');
  sb.writeln('Top contributors driving this project:');
  for (final contributor in busFactorResult.topContributors) {
    final percentage = (contributor.percentage * 100).toStringAsFixed(1);
    sb.writeln('- **`${contributor.author}`**: ${contributor.contributions} commits ($percentage%)');
  }

  final reportMarkdown = sb.toString();
  GitHub.writeStepSummary(reportMarkdown);

  if (hasWarnings && token.isNotEmpty) {
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

  if (failOnWarning && hasWarnings) {
    stderr.writeln('pr-risk-analyzer: failing due to warnings found.');
    exitCode = 1;
  }
}
