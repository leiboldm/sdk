// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart2js.serialization_compilation_test;

import 'dart:async';
import 'package:async_helper/async_helper.dart';
import 'package:compiler/src/compiler.dart';
import 'package:compiler/src/filenames.dart';
import '../memory_compiler.dart';
import 'helper.dart';
import 'test_data.dart';
import '../output_collector.dart';

main(List<String> args) {
  asyncTest(() async {
    Arguments arguments = new Arguments.from(args);
    String serializedData = await serializeDartCore(arguments: arguments);
    if (arguments.filename != null) {
      Uri entryPoint = Uri.base.resolve(nativeToUriPath(arguments.filename));
      await compile(serializedData, entryPoint, null);
    } else {
      Uri entryPoint = Uri.parse('memory:main.dart');
      await arguments.forEachTest(TESTS, (int index, Test test) async {
        await compile(serializedData, entryPoint, test,
                      index: index,
                      verbose: arguments.verbose);
      });
    }
  });
}

Future compile(String serializedData, Uri entryPoint, Test test,
               {int index, bool verbose: false}) async {
  String testDescription =
      test != null ? test.sourceFiles[entryPoint.path] : '${entryPoint}';
  print('------------------------------------------------------------------');
  print('compile ${index != null ? '$index:' :''}${testDescription}');
  print('------------------------------------------------------------------');
  OutputCollector outputCollector = new OutputCollector();
  await runCompiler(
      entryPoint: entryPoint,
      memorySourceFiles: test != null ? test.sourceFiles : const {},
      options: [],
      outputProvider: outputCollector,
      beforeRun: (Compiler compiler) {
        compiler.serialization.deserializeFromText(serializedData);
      });
  if (verbose) {
    print(outputCollector.getOutput('', 'js'));
  }
}
