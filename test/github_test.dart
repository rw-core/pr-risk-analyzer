import 'dart:convert';
import 'dart:io';

import 'package:pr_risk_analyzer/src/github.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('pr_risk_analyzer_test');
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  String writeEvent(Object payload) {
    final file = File('${tmp.path}/event.json')
      ..writeAsStringSync(jsonEncode(payload));
    return file.path;
  }

  group('readPrShas', () {
    test('extracts base and head SHAs from a pull_request event', () {
      final path = writeEvent({
        'pull_request': {
          'number': 7,
          'base': {'sha': 'base-sha'},
          'head': {'sha': 'head-sha'},
        },
      });
      final shas = GitHub.readPrShas(path);
      expect(shas, isNotNull);
      expect(shas!.base, 'base-sha');
      expect(shas.head, 'head-sha');
    });

    test('returns null for a non-PR event', () {
      final path = writeEvent({'ref': 'refs/heads/main'});
      expect(GitHub.readPrShas(path), isNull);
    });

    test('returns null when the event file is missing', () {
      expect(GitHub.readPrShas('${tmp.path}/nope.json'), isNull);
      expect(GitHub.readPrShas(null), isNull);
      expect(GitHub.readPrShas(''), isNull);
    });
  });

  group('prNumber', () {
    test('reads the PR number from the payload', () {
      final path = writeEvent({
        'pull_request': {'number': 42},
      });
      expect(GitHub.prNumber(path), 42);
    });

    test('returns null when absent', () {
      expect(GitHub.prNumber(writeEvent({'ref': 'x'})), isNull);
    });
  });

  group('actions file protocol', () {
    test('writeOutputs appends key=value lines', () {
      final out = File('${tmp.path}/output')..createSync();
      GitHub.writeOutputs({'a': '1', 'b': '2'}, path: out.path);
      GitHub.writeOutputs({'c': '3'}, path: out.path);
      expect(out.readAsStringSync(), 'a=1\nb=2\nc=3\n');
    });

    test('writeStepSummary appends markdown', () {
      final out = File('${tmp.path}/summary')..createSync();
      GitHub.writeStepSummary('# hello', path: out.path);
      expect(out.readAsStringSync(), '# hello\n');
    });
  });
}
