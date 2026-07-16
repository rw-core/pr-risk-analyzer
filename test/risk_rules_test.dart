import 'package:pr_risk_analyzer/src/risk_rules.dart';
import 'package:rw_git/rw_git.dart';
import 'package:test/test.dart';

ChurnMetricsWithAuthorsDto churnOf(Map<String, Map<String, int>> perFile) {
  final fileChurn = <String, ContributionStats>{};
  for (final entry in perFile.entries) {
    final total = entry.value.values.fold<int>(0, (sum, v) => sum + v);
    fileChurn[entry.key] = ContributionStats(
      total: total,
      authors: entry.value,
    );
  }
  return ChurnMetricsWithAuthorsDto(fileChurn: fileChurn, totalCommits: 0);
}

CompoundRisks compute({
  required List<String> modifiedFiles,
  Set<String> bugHotspotFiles = const {},
  Set<String> volatileFiles = const {},
  Map<String, Map<String, int>> churn = const {},
  Map<String, int> fileComplexity = const {},
  Set<String> refactoredFiles = const {},
  RiskThresholds thresholds = const RiskThresholds(),
}) => computeCompoundRisks(
  modifiedFiles: modifiedFiles,
  bugHotspotFiles: bugHotspotFiles,
  volatileFiles: volatileFiles,
  historicalChurn: churnOf(churn),
  fileComplexity: fileComplexity,
  refactoredFiles: refactoredFiles,
  thresholds: thresholds,
);

void main() {
  group('tribal knowledge', () {
    test('flags a hotspot owned by a single author', () {
      final risks = compute(
        modifiedFiles: ['a.dart'],
        bugHotspotFiles: {'a.dart'},
        churn: {
          'a.dart': {'Alice': 8, 'Bob': 2},
        },
      );
      expect(risks.tribalKnowledgeFiles, ['a.dart']);
      expect(risks.singleOwnerFiles['Alice'], ['a.dart']);
    });

    test('does not flag a hotspot with shared ownership', () {
      final risks = compute(
        modifiedFiles: ['a.dart'],
        bugHotspotFiles: {'a.dart'},
        churn: {
          'a.dart': {'Alice': 5, 'Bob': 5},
        },
      );
      expect(risks.tribalKnowledgeFiles, isEmpty);
    });

    test('does not flag a single-owner file that is not a hotspot', () {
      final risks = compute(
        modifiedFiles: ['a.dart'],
        churn: {
          'a.dart': {'Alice': 10},
        },
      );
      expect(risks.tribalKnowledgeFiles, isEmpty);
    });
  });

  group('too many cooks', () {
    test('flags a hotspot with three or more minor contributors', () {
      final risks = compute(
        modifiedFiles: ['a.dart'],
        bugHotspotFiles: {'a.dart'},
        churn: {
          'a.dart': {'Alice': 97, 'B': 1, 'C': 1, 'D': 1},
        },
      );
      expect(risks.tooManyCooksFiles, ['a.dart']);
    });

    test('does not flag with only two minor contributors', () {
      final risks = compute(
        modifiedFiles: ['a.dart'],
        bugHotspotFiles: {'a.dart'},
        churn: {
          'a.dart': {'Alice': 98, 'B': 1, 'C': 1},
        },
      );
      expect(risks.tooManyCooksFiles, isEmpty);
    });
  });

  group('departure defect', () {
    test('flags an author solely owning two or more hotspot files', () {
      final risks = compute(
        modifiedFiles: ['a.dart', 'b.dart'],
        bugHotspotFiles: {'a.dart', 'b.dart'},
        churn: {
          'a.dart': {'Alice': 10},
          'b.dart': {'Alice': 9, 'Bob': 1},
        },
      );
      expect(risks.departureDefectAuthors.single.key, 'Alice');
      expect(risks.departureDefectAuthors.single.value, ['a.dart', 'b.dart']);
    });

    test('does not flag an author owning a single hotspot file', () {
      final risks = compute(
        modifiedFiles: ['a.dart'],
        bugHotspotFiles: {'a.dart'},
        churn: {
          'a.dart': {'Alice': 10},
        },
      );
      expect(risks.departureDefectAuthors, isEmpty);
    });
  });

  group('defect injection (absolute thresholds)', () {
    test('flags a high-churn file that also grew in complexity', () {
      final risks = compute(
        modifiedFiles: ['a.dart'],
        churn: {
          'a.dart': {'Alice': 11},
        },
        fileComplexity: {'a.dart': 30},
      );
      expect(risks.defectInjectionFiles, ['a.dart']);
    });

    test('flags a volatile file regardless of churn count', () {
      final risks = compute(
        modifiedFiles: ['a.dart'],
        volatileFiles: {'a.dart'},
        fileComplexity: {'a.dart': 30},
      );
      expect(risks.defectInjectionFiles, ['a.dart']);
    });

    test('does not flag high churn without complexity growth', () {
      final risks = compute(
        modifiedFiles: ['a.dart'],
        churn: {
          'a.dart': {'Alice': 11},
        },
        fileComplexity: {'a.dart': 29},
      );
      expect(risks.defectInjectionFiles, isEmpty);
    });

    test('does not flag complexity growth on a quiet file', () {
      final risks = compute(
        modifiedFiles: ['a.dart'],
        churn: {
          'a.dart': {'Alice': 3},
        },
        fileComplexity: {'a.dart': 100},
      );
      expect(risks.defectInjectionFiles, isEmpty);
    });

    test('honours custom thresholds', () {
      final risks = compute(
        modifiedFiles: ['a.dart'],
        churn: {
          'a.dart': {'Alice': 3},
        },
        fileComplexity: {'a.dart': 5},
        thresholds: const RiskThresholds(
          highChurnCommits: 2,
          highComplexityGrowth: 5,
        ),
      );
      expect(risks.defectInjectionFiles, ['a.dart']);
    });
  });

  group('clean-up exception', () {
    test('flags a high-churn file touched by a refactoring', () {
      final risks = compute(
        modifiedFiles: ['a.dart'],
        churn: {
          'a.dart': {'Alice': 11},
        },
        refactoredFiles: {'a.dart'},
      );
      expect(risks.cleanUpExceptionFiles, ['a.dart']);
    });

    test('ignores refactored files without churn', () {
      final risks = compute(
        modifiedFiles: ['a.dart'],
        refactoredFiles: {'a.dart'},
      );
      expect(risks.cleanUpExceptionFiles, isEmpty);
    });
  });

  group('hasAny', () {
    test('is false when nothing was flagged', () {
      expect(compute(modifiedFiles: ['a.dart']).hasAny, isFalse);
    });

    test('is true when any rule fired', () {
      final risks = compute(
        modifiedFiles: ['a.dart'],
        volatileFiles: {'a.dart'},
        fileComplexity: {'a.dart': 30},
      );
      expect(risks.hasAny, isTrue);
    });
  });

  group('extractRefactoredFiles', () {
    test('includes both the raw pair entry and the destination path', () {
      final files = extractRefactoredFiles([
        RefactoringDto(
          commitHash: 'h',
          author: 'Alice',
          date: 'd',
          message: 'refactor: move',
          renamedFiles: ['old.dart -> new.dart'],
          linesInserted: 0,
          linesDeleted: 0,
          isSimplification: false,
        ),
      ]);
      expect(files, contains('new.dart'));
      expect(files, contains('old.dart -> new.dart'));
    });

    test('is empty when no refactorings were detected', () {
      expect(extractRefactoredFiles([]), isEmpty);
    });
  });
}
