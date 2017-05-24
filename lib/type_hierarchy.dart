import 'dart:convert' show JsonEncoder;
import 'dart:io';

import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/error/error.dart';
import 'package:analyzer/file_system/file_system.dart' as fileSystem;
import 'package:analyzer/file_system/physical_file_system.dart';
import 'package:analyzer/source/package_map_resolver.dart';
import 'package:analyzer/src/dart/sdk/sdk.dart';
import 'package:analyzer/src/generated/engine.dart';
import 'package:analyzer/src/context/builder.dart';
import 'package:analyzer/src/generated/java_io.dart';
import 'package:analyzer/src/generated/sdk.dart';
import 'package:analyzer/src/generated/source.dart';
import 'package:analyzer/src/generated/source_io.dart';
import 'package:analyzer/src/generated/utilities_dart.dart';
import 'package:cli_util/cli_util.dart' as cli_util;
import 'package:path/path.dart' as path;

void main(List<String> args) {
  // This script expects to be run from flutter/type_hierarchy.
  String flutterPath =
      path.join(Directory.current.path, '..', 'flutter', 'packages', 'flutter');
  Directory flutterDir = new Directory(flutterPath);
  if (!flutterDir.existsSync()) {
    stderr
        .writeln('This script expects to be run from flutter/type_hierarchy.');
    stderr.writeln('flutter/flutter should be a sibling project.');
    exit(1);
  }

  Directory sdkDir = cli_util.getSdkDir();
  if (sdkDir == null) {
    stderr.writeln('Unable to locate the Dart SDK.');
    stderr
        .writeln('Please start the tool with the --dart-sdk=/path/to/sdk arg.');
    exit(1);
  }

  TypeBuilder builder = new TypeBuilder(sdkDir, flutterDir);
  builder.build();
  exit(builder.hadErrors ? 1 : 0);
}

class TypeBuilder {
  final Directory sdkDir;
  final Directory projectDir;

  List<AnalysisError> errors;
  Map<ClassElement, Set<ClassElement>> childMap;
  List<FlutterType> types;

  TypeBuilder(this.sdkDir, this.projectDir);

  void build() {
    Stopwatch watch = new Stopwatch()..start();

    String libDir = path.normalize(path.join(projectDir.path, 'lib'));
    List<String> files = new List.from(new Directory(libDir)
        .listSync(followLinks: false)
        .where((FileSystemEntity entity) =>
            entity is File && entity.path.endsWith('.dart'))
        .map((e) => e.path));

    print('Found ${files.length} source files.');

    fileSystem.ResourceProvider resourceProvider = PhysicalResourceProvider.INSTANCE;
    ContextBuilder builder = new ContextBuilder(resourceProvider, null, null);

    Set<LibraryElement> libraries = new Set();
    DartSdk sdk = new FolderBasedDartSdk(resourceProvider, resourceProvider.getFolder(sdkDir.path));
    Map<String, List<fileSystem.Folder>> packageMap =
        builder.convertPackagesToMap(builder.createPackageMap(projectDir.path));
    List<UriResolver> resolvers = [
      new DartUriResolver(sdk),
      new PackageMapUriResolver(resourceProvider, packageMap),
      new fileSystem.ResourceUriResolver(PhysicalResourceProvider.INSTANCE)
    ];

    SourceFactory sourceFactory = new SourceFactory(resolvers);

    AnalysisEngine.instance.processRequiredPlugins();

    AnalysisContext context = AnalysisEngine.instance.createAnalysisContext()
      ..sourceFactory = sourceFactory;

    List<Source> sources = [];

    files.forEach((String filePath) {
      String name = filePath;
      if (name.startsWith(Directory.current.path)) {
        name = name.substring(Directory.current.path.length);
        if (name.startsWith(Platform.pathSeparator)) name = name.substring(1);
      }
      print('  parsing ${name}…');
      JavaFile javaFile = new JavaFile(filePath);
      Source source = new FileBasedSource(new JavaFile(filePath));
      Uri uri = context.sourceFactory.restoreUri(source);
      if (uri != null) {
        source = new FileBasedSource(javaFile, uri);
      }
      sources.add(source);
      if (context.computeKindOf(source) == SourceKind.LIBRARY) {
        LibraryElement library = context.computeLibraryElement(source);
        libraries.add(library);
      }
    });

    print('');
    print('resolving…');

    // Ensure that the analysis engine performs all remaining work.
    AnalysisResult result = context.performAnalysisTask();
    while (result.hasMoreWork) {
      result = context.performAnalysisTask();
    }

    errors = [];

    for (Source source in sources) {
      context.computeErrors(source);
      errors.addAll(context.getErrors(source).errors);
    }

    errors = errors.where((AnalysisError error) {
      ErrorSeverity severity = error.errorCode.errorSeverity;
      return severity == ErrorSeverity.WARNING ||
          severity == ErrorSeverity.ERROR;
    }).toList();

    if (errors.isNotEmpty) {
      print('Encountered ${errors.length} analysis issues.');
    }

    childMap = {};
    types = [];

    for (LibraryElement library in libraries) {
      for (CompilationUnitElement unit in library.units) {
        for (ClassElement type in unit.types) {
          _addType(library, type);
        }
      }

      for (LibraryElement exportedLibrary in library.exportedLibraries) {
        for (CompilationUnitElement unit in exportedLibrary.units) {
          for (ClassElement type in unit.types) {
            _addType(library, type);
          }
        }
      }
    }

    for (FlutterType type in types) {
      type._parent = findType(type.type.supertype?.element?.name);

      if (childMap[type.type] == null) continue;

      for (ClassElement child in childMap[type.type]) {
        FlutterType flutterChild = findType(child.name);
        if (flutterChild != null) type._children.add(flutterChild);
      }
    }

    // TODO: this is not returning the widgets in the material library
    // widgets/framework.dart Widget
    FlutterType widget = findType('Widget');
    List<FlutterType> widgets = widget.getPublicDescendants().toList()
      ..add(widget);

    widgets.sort((FlutterType a, FlutterType b) {
      return a.name.compareTo(b.name);
    });

    print('');

    emitJson(widgets);

    print(
        'Finished in ${(watch.elapsedMilliseconds / 1000.0).toStringAsFixed(2)}s.');
  }

  void emitJson(List<FlutterType> widgets) {
    var data = {};

    for (FlutterType widget in widgets) {
      data[widget.name] = _widgetToMap(widget);
    }

    JsonEncoder encoder = new JsonEncoder.withIndent('  ');
    String jsonText = encoder.convert(data);
    File file = new File('widgets.json');
    file.writeAsStringSync('$jsonText\n');

    print('Wrote data for ${widgets.length} widgets to ${file.path}.');
  }

  Map _widgetToMap(FlutterType widget) {
    Map m = {'name': widget.name, 'package': widget.package};

    if (widget.parent != null) m['parent'] = widget.parent.name;
    if (widget.abstract) m['abstract'] = widget.abstract;
    if (widget.hasDocumentation) m['docs'] = widget.documentation;

    if (widget.properties.isNotEmpty) {
      m['properties'] = widget.properties.map((FlutterProperty property) {
        Map map = {'name': property.name, 'type': property.type};
        if (!property.isFinal) map['mutable'] = !property.isFinal;
        if (property.isNamed) map['named'] = true;
        if (property.isRequired) map['required'] = true;
        if (property.hasDocs) map['docs'] = property.documentation;
        return map;
      }).toList();
    }

    return m;
  }

  bool get hadErrors => errors.isNotEmpty;

  FlutterType findType(String name) {
    return types.firstWhere((t) => t.name == name, orElse: () => null);
  }

  void _addType(LibraryElement mainLibrary, ClassElement type) {
    types.add(new FlutterType(mainLibrary.name, type));

    ClassElement parent = type.supertype?.element;
    if (parent != null) {
      if (childMap[parent] == null) {
        childMap[parent] = new Set();
      }
      childMap[parent].add(type);
    }
  }
}

class FlutterType {
  final String package;
  final ClassElement type;

  FlutterType _parent;
  List<FlutterType> _children = [];
  List<FlutterProperty> _properties = [];

  FlutterType(this.package, this.type) {
    // Build the properties from the default ctor.
    ConstructorElement ctor = type.constructors.first;
    // firstWhere((ctor) => ctor.isDefaultConstructor, orElse: () => null);
    if (ctor != null) {
      _properties = ctor.parameters
          .map((ParameterElement param) => new FlutterProperty(param))
          .toList();
    }
  }

  bool get abstract => type.isAbstract;

  bool get private => type.name.startsWith('_');

  bool get hasDocumentation => type.documentationComment != null;

  String get documentation {
    return type.documentationComment
        .split('\n')
        .map((s) => _removeComments(s))
        .map((s) => s.trim())
        .join('\n')
        .trim();
  }

  String get name => type.name;

  List<FlutterProperty> get properties => _properties;

  FlutterType get parent => _parent;

  List<FlutterType> get children => _children;

  String get fullName => '$package.${type.name}';

  Iterable<FlutterType> getDescendants() {
    return []
      ..addAll(children)
      ..addAll(children.expand((FlutterType type) => type._children));
  }

  Iterable<FlutterType> getPublicDescendants() {
    Iterable<FlutterType> kids = _children.where((type) => !type.private);
    return []
      ..addAll(kids)
      ..addAll(kids.expand((FlutterType type) => type.getPublicDescendants()));
  }

  String toString() => type.name;
}

class FlutterProperty {
  final ParameterElement _param;

  FlutterProperty(this._param);

  String get name => _param.name;
  String get type => _param.type.name;

  bool get isFinal => _targetField != null ? _targetField.isFinal : true;

  bool get isNamed => _param.parameterKind == ParameterKind.NAMED;

  bool get isRequired => _param.parameterKind == ParameterKind.REQUIRED ||
      _param.metadata.any((a) => a.isRequired);

  bool get hasDocs =>
      _targetField != null ? _targetField.documentationComment != null : false;

  String get documentation {
    return _targetField.documentationComment
        .split('\n')
        .map((s) => _removeComments(s))
        .map((s) => s.trim())
        .join('\n')
        .trim();
  }

  FieldElement get _targetField {
    if (_param is FieldFormalParameterElement) {
      return (_param as FieldFormalParameterElement).field;
    } else {
      return null;
    }
  }
}

//String _docSummary(String docs) {
//  if (docs == null) return null;
//
//  return docs.split('\n').takeWhile((s) => s.isNotEmpty).join(' ');
//}

String _removeComments(String s) {
  if (s.startsWith('///')) return s.substring(3);
  if (s.startsWith('/*')) return s.substring(2);
  if (s.startsWith(' *')) return s.substring(2);
  if (s.startsWith('*')) return s.substring(1);
  if (s.endsWith('*/')) return s.substring(0, s.length - 2);

  return s;
}
