import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Thin wrapper over the GitHub REST API and the Actions runner file protocol
/// (`$GITHUB_STEP_SUMMARY`, `$GITHUB_OUTPUT`).
class GitHub {
  GitHub({
    required this.token,
    required this.repository,
    http.Client? client,
    String? apiUrl,
  })  : _client = client ?? http.Client(),
        _apiUrl = apiUrl ?? 'https://api.github.com';

  final String token;

  /// `owner/repo`.
  final String repository;
  final http.Client _client;
  final String _apiUrl;
  
  static const marker = '<!-- pr-risk-analyzer-marker -->';

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $token',
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'Content-Type': 'application/json',
      };

  /// Appends [markdown] to the job summary shown in the Actions run.
  static void writeStepSummary(String markdown, {String? path}) {
    final target = path ?? Platform.environment['GITHUB_STEP_SUMMARY'];
    if (target == null || target.isEmpty) return;
    File(target).writeAsStringSync('$markdown\n', mode: FileMode.append);
  }

  /// Writes action outputs via the `$GITHUB_OUTPUT` file protocol.
  static void writeOutputs(Map<String, String> outputs, {String? path}) {
    final target = path ?? Platform.environment['GITHUB_OUTPUT'];
    if (target == null || target.isEmpty) return;
    final sb = StringBuffer();
    outputs.forEach((k, v) => sb.writeln('$k=$v'));
    File(target).writeAsStringSync(sb.toString(), mode: FileMode.append);
  }

  /// Reads the PR number from the GitHub event payload.
  static int? prNumber(String? eventPath) {
    if (eventPath == null || eventPath.isEmpty) return null;
    final file = File(eventPath);
    if (!file.existsSync()) return null;
    final payload = jsonDecode(file.readAsStringSync());
    if (payload is! Map) return null;
    final n = (payload['pull_request'] as Map?)?['number'] ?? payload['number'];
    return n is int ? n : int.tryParse('$n');
  }

  /// Extracts base/head SHAs from the GitHub event payload at
  /// `GITHUB_EVENT_PATH`. Returns null when the event is not a pull request.
  static ({String base, String head})? readPrShas(String? eventPath) {
    if (eventPath == null || eventPath.isEmpty) return null;
    final file = File(eventPath);
    if (!file.existsSync()) return null;
    final payload = jsonDecode(file.readAsStringSync());
    if (payload is! Map || payload['pull_request'] is! Map) return null;
    final pr = payload['pull_request'] as Map;
    final base = (pr['base'] as Map?)?['sha'] as String?;
    final head = (pr['head'] as Map?)?['sha'] as String?;
    if (base == null || head == null) return null;
    return (base: base, head: head);
  }

  /// Creates the sticky comment on [issueNumber], or edits the existing one
  /// (identified by [marker]) when present.
  Future<void> upsertStickyComment(int issueNumber, String body) async {
    final finalBody = '$body\n\n$marker';
    final existingId = await _findMarkerComment(issueNumber);
    if (existingId != null) {
      await _client.patch(
        Uri.parse('$_apiUrl/repos/$repository/issues/comments/$existingId'),
        headers: _headers,
        body: jsonEncode({'body': finalBody}),
      );
    } else {
      await _client.post(
        Uri.parse('$_apiUrl/repos/$repository/issues/$issueNumber/comments'),
        headers: _headers,
        body: jsonEncode({'body': finalBody}),
      );
    }
  }

  Future<int?> _findMarkerComment(int issueNumber) async {
    for (var page = 1; page <= 10; page++) {
      final res = await _client.get(
        Uri.parse('$_apiUrl/repos/$repository/issues/$issueNumber/comments'
            '?per_page=100&page=$page'),
        headers: _headers,
      );
      if (res.statusCode != 200) return null;
      final list = jsonDecode(res.body);
      if (list is! List || list.isEmpty) return null;
      for (final c in list) {
        if (c is Map && (c['body'] as String? ?? '').contains(marker)) {
          return c['id'] as int?;
        }
      }
      if (list.length < 100) return null;
    }
    return null;
  }

  void close() => _client.close();
}
