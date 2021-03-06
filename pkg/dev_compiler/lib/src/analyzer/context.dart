// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:args/args.dart' show ArgParser, ArgResults;
import 'package:analyzer/src/command_line/arguments.dart';
import 'package:analyzer/file_system/file_system.dart'
    show ResourceProvider, ResourceUriResolver;
import 'package:analyzer/file_system/physical_file_system.dart'
    show PhysicalResourceProvider;
import 'package:analyzer/source/custom_resolver.dart';
import 'package:analyzer/source/package_map_resolver.dart';
import 'package:analyzer/src/context/builder.dart';
import 'package:analyzer/src/context/context.dart' show AnalysisContextImpl;
import 'package:analyzer/src/dart/sdk/sdk.dart' show FolderBasedDartSdk;
import 'package:analyzer/src/generated/engine.dart'
    show AnalysisEngine, AnalysisOptionsImpl;
import 'package:analyzer/src/generated/source.dart'
    show DartUriResolver, SourceFactory, UriResolver;
import 'package:analyzer/src/summary/package_bundle_reader.dart'
    show InSummaryUriResolver, SummaryDataStore;
import 'package:analyzer/src/summary/summary_sdk.dart' show SummaryBasedDartSdk;
import 'package:cli_util/cli_util.dart' show getSdkDir;
import 'package:path/path.dart' as path;

/// Options used to set up Source URI resolution in the analysis context.
class AnalyzerOptions {
  final ContextBuilderOptions contextBuilderOptions;

  /// Custom URI mappings, such as "dart:foo" -> "path/to/foo.dart"
  final Map<String, String> customUrlMappings;

  /// Package root when resolving 'package:' urls the standard way.
  String get packageRoot => contextBuilderOptions.defaultPackagesDirectoryPath;

  /// List of summary file paths.
  final List<String> summaryPaths;

  /// Path to the dart-sdk. Null if `useMockSdk` is true or if the path couldn't
  /// be determined
  final String dartSdkPath;

  /// Path to the dart-sdk summary.  If this is set, it will be used in favor
  /// of the unsummarized one.
  String get dartSdkSummaryPath => contextBuilderOptions.dartSdkSummaryPath;

  /// Defined variables used by `bool.fromEnvironment` etc.
  Map<String, String> get declaredVariables =>
      contextBuilderOptions.declaredVariables;

  AnalyzerOptions._(
      {this.contextBuilderOptions,
      this.summaryPaths: const [],
      String dartSdkPath,
      this.customUrlMappings: const {}})
      : dartSdkPath = dartSdkPath ?? getSdkDir().path {
    contextBuilderOptions.declaredVariables ??= const {};
  }

  factory AnalyzerOptions.basic(
      {String dartSdkPath,
      String dartSdkSummaryPath,
      List<String> summaryPaths}) {
    var contextBuilderOptions = new ContextBuilderOptions();
    contextBuilderOptions.dartSdkSummaryPath = dartSdkSummaryPath;

    return new AnalyzerOptions._(
        contextBuilderOptions: contextBuilderOptions,
        dartSdkPath: dartSdkPath,
        summaryPaths: summaryPaths);
  }

  factory AnalyzerOptions.fromArguments(ArgResults args,
      {String dartSdkSummaryPath, List<String> summaryPaths}) {
    var contextBuilderOptions = createContextBuilderOptions(args);

    if (dartSdkSummaryPath != null)
      contextBuilderOptions.dartSdkSummaryPath = dartSdkSummaryPath;
    contextBuilderOptions.dartSdkSummaryPath ??=
        path.join(args['dart-sdk'], 'lib', '_internal', 'ddc_sdk.sum');
    if (contextBuilderOptions.dartSdkSummaryPath == 'build') {
      // For building the SDK, we explicitly set the path to none.
      contextBuilderOptions.dartSdkSummaryPath = null;
    }

    return new AnalyzerOptions._(
        contextBuilderOptions: contextBuilderOptions,
        summaryPaths: summaryPaths ?? args['summary'] as List<String>,
        dartSdkPath: args['dart-sdk'],
        customUrlMappings: _parseUrlMappings(args['url-mapping']));
  }

  static void addArguments(ArgParser parser, {bool hide: true}) {
    parser
      ..addOption('summary',
          abbr: 's', help: 'summary file(s) to include', allowMultiple: true)
      ..addOption('url-mapping',
          help: '--url-mapping=libraryUri,/path/to/library.dart uses\n'
              'library.dart as the source for an import of of "libraryUri".',
          allowMultiple: true,
          splitCommas: false);
  }

  static Map<String, String> _parseUrlMappings(Iterable argument) {
    var mappings = <String, String>{};
    for (var mapping in argument) {
      var splitMapping = mapping.split(',');
      if (splitMapping.length >= 2) {
        mappings[splitMapping[0]] = path.absolute(splitMapping[1]);
      }
    }
    return mappings;
  }
}

/// Creates an analysis context that contains our restricted typing rules.
AnalysisContextImpl createAnalysisContext() {
  var res = AnalysisEngine.instance.createAnalysisContext();
  res.analysisOptions = new AnalysisOptionsImpl()
    ..strongMode = true
    ..trackCacheDependencies = false;
  return res;
}

/// Creates a SourceFactory configured by the [options].
///
/// Use [options.useMockSdk] to specify the SDK mode, or use [sdkResolver]
/// to entirely override the DartUriResolver.
///
/// If supplied, [fileResolvers] will override the default `file:` and
/// `package:` URI resolvers.
SourceFactory createSourceFactory(AnalyzerOptions options,
    {DartUriResolver sdkResolver,
    List<UriResolver> fileResolvers,
    SummaryDataStore summaryData,
    ResourceProvider resourceProvider}) {
  resourceProvider ??= PhysicalResourceProvider.INSTANCE;
  var resolvers = <UriResolver>[];
  if (options.customUrlMappings.isNotEmpty) {
    resolvers.add(
        new CustomUriResolver(resourceProvider, options.customUrlMappings));
  }
  resolvers.add(sdkResolver);
  if (summaryData != null) {
    resolvers.add(new InSummaryUriResolver(resourceProvider, summaryData));
  }

  if (fileResolvers == null)
    fileResolvers =
        createFileResolvers(options, resourceProvider: resourceProvider);
  resolvers.addAll(fileResolvers);
  return new SourceFactory(resolvers, null, resourceProvider);
}

List<UriResolver> createFileResolvers(AnalyzerOptions options,
    {ResourceProvider resourceProvider}) {
  resourceProvider ??= PhysicalResourceProvider.INSTANCE;
  UriResolver packageResolver() {
    ContextBuilderOptions builderOptions = new ContextBuilderOptions();
    if (options.packageRoot != null) {
      builderOptions.defaultPackagesDirectoryPath = options.packageRoot;
    }
    ContextBuilder builder = new ContextBuilder(resourceProvider, null, null,
        options: builderOptions);
    return new PackageMapUriResolver(resourceProvider,
        builder.convertPackagesToMap(builder.createPackageMap('')));
  }

  return [new ResourceUriResolver(resourceProvider), packageResolver()];
}

FolderBasedDartSdk _createFolderBasedDartSdk(String sdkPath) {
  var resourceProvider = PhysicalResourceProvider.INSTANCE;
  var sdk = new FolderBasedDartSdk(resourceProvider,
      resourceProvider.getFolder(sdkPath), /*useDart2jsPaths:*/ true);
  sdk.useSummary = true;
  sdk.analysisOptions = new AnalysisOptionsImpl()..strongMode = true;
  return sdk;
}

/// Creates a [DartUriResolver] that uses the SDK at the given [sdkPath].
DartUriResolver createSdkPathResolver(String sdkSummaryPath, String sdkPath) {
  var sdk = (sdkSummaryPath != null)
      ? new SummaryBasedDartSdk(sdkSummaryPath, true)
      : _createFolderBasedDartSdk(sdkPath);
  return new DartUriResolver(sdk);
}
