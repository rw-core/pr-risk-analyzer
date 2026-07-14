import 'package:rw_git/rw_git.dart';
import 'package:pr_risk_analyzer/src/github.dart';
import 'dart:io';

void main() async {
  final runner = ProcessRunner.defaultRunner();
  final repo = Directory.current.absolute.path;
  print("Repo: \$repo");
  
  final szz = SzzAlgorithm(runner);
  // Szz doesn't return anything unless there are actual bug hotspots, but we can reflect its return type
  print(szz.runtimeType);
}
