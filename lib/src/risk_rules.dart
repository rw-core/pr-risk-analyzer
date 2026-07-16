import 'package:rw_git/rw_git.dart';

/// Pure computation of the compound PR risk rules over rw_git DTOs, kept
/// free of I/O so the rules are unit-testable and `bin/main.dart` stays
/// orchestration + rendering only.
///
/// All thresholds are absolute. Every input is scoped to the PR's modified
/// files, so repo-relative baselines (percentiles against the whole
/// repository's churn/complexity distribution) are not computable here by
/// design — the analyzer must not scan history outside the PR's files.
class RiskThresholds {
  const RiskThresholds({
    this.singleOwnerShare = 0.5,
    this.minorContributorShare = 0.05,
    this.minMinorContributors = 3,
    this.highChurnCommits = 10,
    this.highComplexityGrowth = 30,
    this.departureMinOwnedHotspots = 2,
  });

  /// An author with more than this share of a file's commits is its single
  /// owner (Avelino et al., 2016).
  final double singleOwnerShare;

  /// Contributors below this share of a file's commits count as minor
  /// (Bird et al., FSE 2011).
  final double minorContributorShare;

  /// Minor contributors at or above this count flag "too many cooks".
  final int minMinorContributors;

  /// A file with more commits than this in the history window counts as
  /// high-churn (Nagappan & Ball, 2005).
  final int highChurnCommits;

  /// Control-flow tokens (`if`/`for`/`while`/`switch`/`&&`/`||`/`?`) added
  /// to a file across the history window at or above this count mark the
  /// file as growing in complexity (proxy from
  /// [AdvancedMetricsHeuristic.calculateAdvancedMetrics]).
  final int highComplexityGrowth;

  /// An author solely owning at least this many hotspot files is a
  /// departure risk (Mockus & Herbsleb, 2002).
  final int departureMinOwnedHotspots;
}

/// The classified compound risks for one PR.
class CompoundRisks {
  CompoundRisks({
    required this.tribalKnowledgeFiles,
    required this.tooManyCooksFiles,
    required this.defectInjectionFiles,
    required this.cleanUpExceptionFiles,
    required this.singleOwnerFiles,
    required this.departureDefectAuthors,
  });

  /// Bug hotspots owned by a single author.
  final List<String> tribalKnowledgeFiles;

  /// Bug hotspots with three or more minor contributors.
  final List<String> tooManyCooksFiles;

  /// High-churn/volatile files that also grew in complexity.
  final List<String> defectInjectionFiles;

  /// High-churn/volatile files whose churn is explained by refactorings.
  final List<String> cleanUpExceptionFiles;

  /// Single owner -> the tribal-knowledge files they own.
  final Map<String, List<String>> singleOwnerFiles;

  /// Authors solely owning enough hotspot files to be a departure risk.
  final List<MapEntry<String, List<String>>> departureDefectAuthors;

  bool get hasAny =>
      tribalKnowledgeFiles.isNotEmpty ||
      tooManyCooksFiles.isNotEmpty ||
      departureDefectAuthors.isNotEmpty ||
      defectInjectionFiles.isNotEmpty ||
      cleanUpExceptionFiles.isNotEmpty;
}

/// Flattens rw_git's refactoring results into the set of file paths touched
/// by a detected refactoring. `renamedFiles` entries are `old -> new`
/// pairs; both the raw entry and the destination path are included so
/// membership checks work against post-rename paths.
Set<String> extractRefactoredFiles(List<RefactoringDto> refactorings) {
  final refactoredFiles = <String>{};
  for (final ref in refactorings) {
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
  return refactoredFiles;
}

/// Applies the compound risk rules to the PR's modified files.
///
/// [historicalChurn] and [fileComplexity] must come from analyses scoped to
/// [modifiedFiles] over the analyzer's history window.
CompoundRisks computeCompoundRisks({
  required List<String> modifiedFiles,
  required Set<String> bugHotspotFiles,
  required Set<String> volatileFiles,
  required ChurnMetricsWithAuthorsDto historicalChurn,
  required Map<String, int> fileComplexity,
  required Set<String> refactoredFiles,
  RiskThresholds thresholds = const RiskThresholds(),
}) {
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
        if (percentage > thresholds.singleOwnerShare) {
          hasSingleOwner = true;
          singleOwner = entry.key;
        }
        if (percentage < thresholds.minorContributorShare) minorContributors++;
      }
      if (minorContributors >= thresholds.minMinorContributors) {
        hasTooManyCooks = true;
      }
    }

    final isHotspot = bugHotspotFiles.contains(file);
    final isVolatile = volatileFiles.contains(file);
    final isHighChurn =
        isVolatile || totalCommits > thresholds.highChurnCommits;
    final complexity = fileComplexity[file] ?? 0;

    if (isHotspot && hasSingleOwner) {
      tribalKnowledgeFiles.add(file);
      if (singleOwner != null) {
        singleOwnerFiles.putIfAbsent(singleOwner, () => []).add(file);
      }
    }

    if (isHotspot && hasTooManyCooks) {
      tooManyCooksFiles.add(file);
    }

    if (isHighChurn && complexity >= thresholds.highComplexityGrowth) {
      defectInjectionFiles.add(file);
    }

    if (isHighChurn && refactoredFiles.contains(file)) {
      cleanUpExceptionFiles.add(file);
    }
  }

  final departureDefectAuthors = singleOwnerFiles.entries
      .where((e) => e.value.length >= thresholds.departureMinOwnedHotspots)
      .toList();

  return CompoundRisks(
    tribalKnowledgeFiles: tribalKnowledgeFiles,
    tooManyCooksFiles: tooManyCooksFiles,
    defectInjectionFiles: defectInjectionFiles,
    cleanUpExceptionFiles: cleanUpExceptionFiles,
    singleOwnerFiles: singleOwnerFiles,
    departureDefectAuthors: departureDefectAuthors,
  );
}
