// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart._js_mirrors;

import 'dart:async';

import 'dart:collection' show
    UnmodifiableListView;

import 'dart:mirrors';

import 'dart:_foreign_helper' show
    JS,
    JS_CURRENT_ISOLATE,
    JS_CURRENT_ISOLATE_CONTEXT,
    JS_GET_NAME;

import 'dart:_collection-dev' as _symbol_dev;

import 'dart:_js_helper' show
    BoundClosure,
    Closure,
    JSInvocationMirror,
    JsCache,
    Null,
    Primitives,
    ReflectionInfo,
    RuntimeError,
    TypeVariable,
    UnimplementedNoSuchMethodError,
    createRuntimeType,
    createUnmangledInvocationMirror,
    getMangledTypeName,
    getMetadata,
    hasReflectableProperty,
    runtimeTypeToString,
    setRuntimeTypeInfo,
    throwInvalidReflectionError;

import 'dart:_interceptors' show
    Interceptor,
    JSArray,
    JSExtendableArray,
    getInterceptor;

import 'dart:_js_names';

const String METHODS_WITH_OPTIONAL_ARGUMENTS = r'$methodsWithOptionalArguments';

/// No-op method that is called to inform the compiler that tree-shaking needs
/// to be disabled.
disableTreeShaking() => preserveNames();

/// No-op method that is called to inform the compiler that metadata must be
/// preserved at runtime.
preserveMetadata() {}

String getName(Symbol symbol) {
  preserveNames();
  return n(symbol);
}

class JsMirrorSystem implements MirrorSystem {
  UnmodifiableMapView<Uri, LibraryMirror> _cachedLibraries;

  final IsolateMirror isolate = new JsIsolateMirror();

  JsTypeMirror get dynamicType => _dynamicType;
  JsTypeMirror get voidType => _voidType;

  final static JsTypeMirror _dynamicType =
      new JsTypeMirror(const Symbol('dynamic'));
  final static JsTypeMirror _voidType = new JsTypeMirror(const Symbol('void'));

  static final Map<String, List<LibraryMirror>> librariesByName =
      computeLibrariesByName();

  Map<Uri, LibraryMirror> get libraries {
    if (_cachedLibraries != null) return _cachedLibraries;
    Map<Uri, LibraryMirror> result = new Map();
    for (List<LibraryMirror> list in librariesByName.values) {
      for (LibraryMirror library in list) {
        result[library.uri] = library;
      }
    }
    return _cachedLibraries =
        new UnmodifiableMapView<Uri, LibraryMirror>(result);
  }

  LibraryMirror findLibrary(Symbol libraryName) {
    return librariesByName[n(libraryName)].single;
  }

  static Map<String, List<LibraryMirror>> computeLibrariesByName() {
    disableTreeShaking();
    var result = new Map<String, List<LibraryMirror>>();
    var jsLibraries = JS('JSExtendableArray|Null', 'init.libraries');
    if (jsLibraries == null) return result;
    for (List data in jsLibraries) {
      String name = data[0];
      Uri uri = Uri.parse(data[1]);
      List<String> classes = data[2];
      List<String> functions = data[3];
      var metadataFunction = data[4];
      var fields = data[5];
      bool isRoot = data[6];
      var globalObject = data[7];
      List metadata = (metadataFunction == null)
          ? const [] : JS('List', '#()', metadataFunction);
      var libraries = result.putIfAbsent(name, () => <LibraryMirror>[]);
      libraries.add(
          new JsLibraryMirror(
              s(name), uri, classes, functions, metadata, fields, isRoot,
              globalObject));
    }
    return result;
  }
}

abstract class JsMirror implements Mirror {
  const JsMirror();

  String get _prettyName;

  String toString() => _prettyName;

  // TODO(ahe): Remove this method from the API.
  MirrorSystem get mirrors => currentJsMirrorSystem;

  _getField(JsMirror receiver) {
    throw new UnimplementedError();
  }

  void _setField(JsMirror receiver, Object arg) {
    throw new UnimplementedError();
  }

  _loadField(String name) {
    throw new UnimplementedError();
  }

  void _storeField(String name, Object arg) {
    throw new UnimplementedError();
  }
}

// TODO(zarah): This should be a common superclass for instead of a common
// interface.
abstract class JsClassMirror implements ClassMirror {
  get _jsConstructor;

  String get _mangledName;

  // For implementation purposes this does not return the same as the api
  // getter for typeVariables. Specifically for mixins we add synthestic type
  // variables.
  List<TypeVariableMirror> get _typeVariables;

  List<TypeMirror> get _typeArguments;

  List<VariableMirror> _getFieldsWithOwner(DeclarationMirror owner);

  List<MethodMirror> _getMethodsWithOwner(DeclarationMirror owner);

  List<ClassMirror> _getSuperinterfacesWithOwner(DeclarationMirror owner);

  _getInvokedInstance(Symbol constructorName,
                      List positionalArguments,
                      [Map<Symbol, dynamic> namedArguments]);
}

// This class is somewhat silly in the current implementation.
class JsIsolateMirror extends JsMirror implements IsolateMirror {
  final _isolateContext = JS_CURRENT_ISOLATE_CONTEXT();

  String get _prettyName => 'Isolate';

  String get debugName {
    String id = _isolateContext == null ? 'X' : _isolateContext.id.toString();
    // Using name similar to what the VM uses.
    return '${n(rootLibrary.simpleName)}-$id';
  }

  bool get isCurrent => JS_CURRENT_ISOLATE_CONTEXT() == _isolateContext;

  LibraryMirror get rootLibrary {
    return currentJsMirrorSystem.libraries.values.firstWhere(
        (JsLibraryMirror library) => library._isRoot);
  }
}

abstract class JsDeclarationMirror extends JsMirror
    implements DeclarationMirror {
  final Symbol simpleName;

  const JsDeclarationMirror(this.simpleName);

  Symbol get qualifiedName => computeQualifiedName(owner, simpleName);

  bool get isPrivate => n(simpleName).startsWith('_');

  bool get isTopLevel => owner != null && owner is LibraryMirror;

  // TODO(ahe): This should use qualifiedName.
  String toString() => "$_prettyName on '${n(simpleName)}'";

  List<JsMethodMirror> get _methods {
    throw new RuntimeError('Should not call _methods');
  }

  _invoke(List positionalArguments, Map<Symbol, dynamic> namedArguments) {
    throw new RuntimeError('Should not call _invoke');
  }

  // TODO(ahe): Implement this.
  SourceLocation get location => throw new UnimplementedError();
}

class JsTypeVariableMirror extends JsTypeMirror implements TypeVariableMirror {
  final DeclarationMirror owner;
  final TypeVariable _typeVariable;
  final int _metadataIndex;
  TypeMirror _cachedUpperBound;

  JsTypeVariableMirror(TypeVariable typeVariable, this.owner,
                       this._metadataIndex)
      : this._typeVariable = typeVariable,
        super(s(typeVariable.name));

  bool operator ==(other) {
    return (other is JsTypeVariableMirror &&
        simpleName == other.simpleName &&
        owner == other.owner);
  }

  int get hashCode {
    int code = 0x3FFFFFFF & (JsTypeVariableMirror).hashCode;
    code ^= 17 * simpleName.hashCode;
    code ^= 19 * owner.hashCode;
    return code;
  }

  String get _prettyName => 'TypeVariableMirror';

  bool get isTopLevel => false;

  TypeMirror get upperBound {
    if (_cachedUpperBound != null) return _cachedUpperBound;
    return _cachedUpperBound = typeMirrorFromRuntimeTypeRepresentation(
        owner, getMetadata(_typeVariable.bound));
  }

  _asRuntimeType() => _metadataIndex;
}

class JsTypeMirror extends JsDeclarationMirror implements TypeMirror {
  JsTypeMirror(Symbol simpleName)
      : super(simpleName);

  String get _prettyName => 'TypeMirror';

  DeclarationMirror get owner => null;

  // TODO(ahe): Doesn't match the specification, see http://dartbug.com/11569.
  bool get isTopLevel => true;

  // TODO(ahe): Implement these.
  List<InstanceMirror> get metadata => throw new UnimplementedError();

  bool get hasReflectedType => false;
  Type get reflectedType {
    throw new UnsupportedError("This type does not support reflectedType");
  }

  List<TypeVariableMirror> get typeVariables => const <TypeVariableMirror>[];
  List<TypeMirror> get typeArguments => const <TypeMirror>[];

  bool get isOriginalDeclaration => true;
  TypeMirror get originalDeclaration => this;

  _asRuntimeType() {
    if (this == JsMirrorSystem._dynamicType) return null;
    if (this == JsMirrorSystem._voidType) return null;
    throw new RuntimeError('Should not call _asRuntimeType');
  }
}

class JsLibraryMirror extends JsDeclarationMirror with JsObjectMirror
    implements LibraryMirror {
  final Uri uri;
  final List<String> _classes;
  final List<String> _functions;
  final List _metadata;
  final String _compactFieldSpecification;
  final bool _isRoot;
  final _globalObject;
  List<JsMethodMirror> _cachedFunctionMirrors;
  List<VariableMirror> _cachedFields;
  UnmodifiableMapView<Symbol, ClassMirror> _cachedClasses;
  UnmodifiableMapView<Symbol, MethodMirror> _cachedFunctions;
  UnmodifiableMapView<Symbol, MethodMirror> _cachedGetters;
  UnmodifiableMapView<Symbol, MethodMirror> _cachedSetters;
  UnmodifiableMapView<Symbol, VariableMirror> _cachedVariables;
  UnmodifiableMapView<Symbol, Mirror> _cachedMembers;
  UnmodifiableMapView<Symbol, DeclarationMirror> _cachedDeclarations;
  UnmodifiableListView<InstanceMirror> _cachedMetadata;

  JsLibraryMirror(Symbol simpleName,
                  this.uri,
                  this._classes,
                  this._functions,
                  this._metadata,
                  this._compactFieldSpecification,
                  this._isRoot,
                  this._globalObject)
      : super(simpleName);

  String get _prettyName => 'LibraryMirror';

  Symbol get qualifiedName => simpleName;

  List<JsMethodMirror> get _methods => _functionMirrors;

  Map<Symbol, ClassMirror> get __classes {
    if (_cachedClasses != null) return _cachedClasses;
    var result = new Map();
    for (String className in _classes) {
      var cls = reflectClassByMangledName(className);
      if (cls is ClassMirror) {
        cls = cls.originalDeclaration;
        if (cls is JsClassDeclarationMirror) {
          result[cls.simpleName] = cls;
          cls._owner = this;
        }
      }
    }
    return _cachedClasses =
        new UnmodifiableMapView<Symbol, ClassMirror>(result);
  }

  InstanceMirror setField(Symbol fieldName, Object arg) {
    String name = n(fieldName);
    if (name.endsWith('=')) throw new ArgumentError('');
    var mirror = __functions[s('$name=')];
    if (mirror == null) mirror = __variables[fieldName];
    if (mirror == null) {
      // TODO(ahe): What receiver to use?
      throw new NoSuchMethodError(this, setterSymbol(fieldName), [arg], null);
    }
    mirror._setField(this, arg);
    return reflect(arg);
  }

  InstanceMirror getField(Symbol fieldName) {
    JsMirror mirror = __members[fieldName];
    if (mirror == null) {
      // TODO(ahe): What receiver to use?
      throw new NoSuchMethodError(this, fieldName, [], null);
    }
    return reflect(mirror._getField(this));
  }

  InstanceMirror invoke(Symbol memberName,
                        List positionalArguments,
                        [Map<Symbol, dynamic> namedArguments]) {
    if (namedArguments != null && !namedArguments.isEmpty) {
      throw new UnsupportedError('Named arguments are not implemented.');
    }
    JsDeclarationMirror mirror = __members[memberName];
    if (mirror == null) {
      // TODO(ahe): What receiver to use?
      throw new NoSuchMethodError(
          this, memberName, positionalArguments, namedArguments);
    }
    if (mirror is JsMethodMirror) {
      JsMethodMirror method = mirror;
      if (!method.canInvokeReflectively()) {
        throwInvalidReflectionError(n(memberName));
      }
    }
    return reflect(mirror._invoke(positionalArguments, namedArguments));
  }

  _loadField(String name) {
    // TODO(ahe): What about lazily initialized fields? See
    // [JsClassMirror.getField].

    // '$' (JS_CURRENT_ISOLATE()) stores state which is read directly, so we
    // shouldn't use [_globalObject] here.
    assert(JS('bool', '# in #', name, JS_CURRENT_ISOLATE()));
    return JS('', '#[#]', JS_CURRENT_ISOLATE(), name);
  }

  void _storeField(String name, Object arg) {
    // '$' (JS_CURRENT_ISOLATE()) stores state which is stored directly, so we
    // shouldn't use [_globalObject] here.
    assert(JS('bool', '# in #', name, JS_CURRENT_ISOLATE()));
    JS('void', '#[#] = #', JS_CURRENT_ISOLATE(), name, arg);
  }

  List<JsMethodMirror> get _functionMirrors {
    if (_cachedFunctionMirrors != null) return _cachedFunctionMirrors;
    var result = new List<JsMethodMirror>();
    for (int i = 0; i < _functions.length; i++) {
      String name = _functions[i];
      var jsFunction = JS('', '#[#]', _globalObject, name);
      String unmangledName = mangledGlobalNames[name];
      if (unmangledName == null) {
        // If there is no unmangledName, [jsFunction] is either a synthetic
        // implementation detail, or something that is excluded
        // by @MirrorsUsed.
        continue;
      }
      bool isConstructor = unmangledName.startsWith('new ');
      bool isStatic = !isConstructor; // Top-level functions are static, but
                                      // constructors are not.
      if (isConstructor) {
        unmangledName = unmangledName.substring(4).replaceAll(r'$', '.');
      }
      JsMethodMirror mirror =
          new JsMethodMirror.fromUnmangledName(
              unmangledName, jsFunction, isStatic, isConstructor);
      result.add(mirror);
      mirror._owner = this;
    }
    return _cachedFunctionMirrors = result;
  }

  List<VariableMirror> get _fields {
    if (_cachedFields != null) return _cachedFields;
    var result = <VariableMirror>[];
    parseCompactFieldSpecification(
        this, _compactFieldSpecification, true, result);
    return _cachedFields = result;
  }

  Map<Symbol, MethodMirror> get __functions {
    if (_cachedFunctions != null) return _cachedFunctions;
    var result = new Map();
    for (JsMethodMirror mirror in _functionMirrors) {
      if (!mirror.isConstructor) result[mirror.simpleName] = mirror;
    }
    return _cachedFunctions =
        new UnmodifiableMapView<Symbol, MethodMirror>(result);
  }

  Map<Symbol, MethodMirror> get __getters {
    if (_cachedGetters != null) return _cachedGetters;
    var result = new Map();
    // TODO(ahe): Implement this.
    return _cachedGetters =
        new UnmodifiableMapView<Symbol, MethodMirror>(result);
  }

  Map<Symbol, MethodMirror> get __setters {
    if (_cachedSetters != null) return _cachedSetters;
    var result = new Map();
    // TODO(ahe): Implement this.
    return _cachedSetters =
        new UnmodifiableMapView<Symbol, MethodMirror>(result);
  }

  Map<Symbol, VariableMirror> get __variables {
    if (_cachedVariables != null) return _cachedVariables;
    var result = new Map();
    for (JsVariableMirror mirror in _fields) {
      result[mirror.simpleName] = mirror;
    }
    return _cachedVariables =
        new UnmodifiableMapView<Symbol, VariableMirror>(result);
  }

  Map<Symbol, Mirror> get __members {
    if (_cachedMembers !=  null) return _cachedMembers;
    Map<Symbol, Mirror> result = new Map.from(__classes);
    addToResult(Symbol key, Mirror value) {
      result[key] = value;
    }
    __functions.forEach(addToResult);
    __getters.forEach(addToResult);
    __setters.forEach(addToResult);
    __variables.forEach(addToResult);
    return _cachedMembers = new UnmodifiableMapView<Symbol, Mirror>(result);
  }

  Map<Symbol, DeclarationMirror> get declarations {
    if (_cachedDeclarations != null) return _cachedDeclarations;
    var result = new Map<Symbol, DeclarationMirror>();
    addToResult(Symbol key, Mirror value) {
      result[key] = value;
    }
    __members.forEach(addToResult);
    return _cachedDeclarations =
        new UnmodifiableMapView<Symbol, DeclarationMirror>(result);
  }

  List<InstanceMirror> get metadata {
    if (_cachedMetadata != null) return _cachedMetadata;
    preserveMetadata();
    return _cachedMetadata =
        new UnmodifiableListView<InstanceMirror>(_metadata.map(reflect));
  }

  // TODO(ahe): Test this getter.
  DeclarationMirror get owner => null;

  // TODO(ahe): Implement this.
  Map<Symbol, MethodMirror> get topLevelMembers
      => throw new UnimplementedError();

  // TODO(ahe): Implement this.
  Function operator [](Symbol name)
      => throw new UnimplementedError();
}

String n(Symbol symbol) => _symbol_dev.Symbol.getName(symbol);

Symbol s(String name) {
  if (name == null) return null;
  return new _symbol_dev.Symbol.unvalidated(name);
}

Symbol setterSymbol(Symbol symbol) => s("${n(symbol)}=");

final JsMirrorSystem currentJsMirrorSystem = new JsMirrorSystem();

InstanceMirror reflect(Object reflectee) {
  if (reflectee is Closure) {
    return new JsClosureMirror(reflectee);
  } else {
    return new JsInstanceMirror(reflectee);
  }
}

TypeMirror reflectType(Type key) {
  return reflectClassByMangledName(getMangledTypeName(key));
}

TypeMirror reflectClassByMangledName(String mangledName) {
  String unmangledName = mangledGlobalNames[mangledName];
  if (mangledName == 'dynamic') return JsMirrorSystem._dynamicType;
  if (unmangledName == null) unmangledName = mangledName;
  return reflectClassByName(s(unmangledName), mangledName);
}

var classMirrors;

TypeMirror reflectClassByName(Symbol symbol, String mangledName) {
  if (classMirrors == null) classMirrors = JsCache.allocate();
  var mirror = JsCache.fetch(classMirrors, mangledName);
  if (mirror != null && mirror is! JsMixinApplication) return mirror;
  disableTreeShaking();
  int typeArgIndex = mangledName.indexOf("<");
  if (typeArgIndex != -1) {
    mirror =
        new JsTypeBoundClassMirror(reflectClassByMangledName(
            mangledName.substring(0, typeArgIndex)).originalDeclaration,
            // Remove the angle brackets enclosing the type arguments.
            mangledName.substring(typeArgIndex + 1, mangledName.length - 1));
    JsCache.update(classMirrors, mangledName, mirror);
    return mirror;
  }
  var constructorOrInterceptor =
      Primitives.getConstructorOrInterceptor(mangledName);
  if (constructorOrInterceptor == null) {
    int index = JS('int|Null', 'init.functionAliases[#]', mangledName);
    if (index != null) {
      mirror = new JsTypedefMirror(symbol, mangledName, getMetadata(index));
      JsCache.update(classMirrors, mangledName, mirror);
      return mirror;
    }
    // Probably an intercepted class.
    // TODO(ahe): How to handle intercepted classes?
    throw new UnsupportedError('Cannot find class for: ${n(symbol)}');
  }
  var constructor = (constructorOrInterceptor is Interceptor)
      ? JS('', '#.constructor', constructorOrInterceptor)
      : constructorOrInterceptor;
  var descriptor = JS('', '#["@"]', constructor);
  var fields;
  var fieldsMetadata;
  if (descriptor == null) {
    // This is a native class, or an intercepted class.
    // TODO(ahe): Preserve descriptor for such classes.
  } else {
    fields = JS('', '#[""]', descriptor);
    if (fields is List) {
      fieldsMetadata = fields.getRange(1, fields.length).toList();
      fields = fields[0];
    }
    if (fields is! String) {
      // TODO(ahe): This is CSP mode.  Find a way to determine the
      // fields of this class.
      fields = '';
    }
  }

  var superclassName = fields.split(';')[0];
  var mixins = superclassName.split('+');
  if (mixins.length > 1 && mangledGlobalNames[mangledName] == null) {
    mirror = reflectMixinApplication(mixins, mangledName, constructor);
  } else {
    ClassMirror classMirror = new JsClassDeclarationMirror(
        symbol, mangledName, constructorOrInterceptor, fields, fieldsMetadata);
    List typeVariables =
        JS('JSExtendableArray|Null', '#.prototype["<>"]', constructor);
    if (typeVariables == null || typeVariables.length == 0) {
      mirror = classMirror;
    } else {
      String typeArguments = 'dynamic';
      for (int i = 1; i < typeVariables.length; i++) {
        typeArguments += ',dynamic';
      }
      mirror = new JsTypeBoundClassMirror(classMirror, typeArguments);
    }
  }

  JsCache.update(classMirrors, mangledName, mirror);
  return mirror;
}

Map<Symbol, MethodMirror> filterMethods(List<MethodMirror> methods) {
  var result = new Map();
  for (JsMethodMirror method in methods) {
    if (!method.isConstructor && !method.isGetter && !method.isSetter) {
      result[method.simpleName] = method;
    }
  }
  return result;
}

Map<Symbol, MethodMirror> filterConstructors(methods) {
  var result = new Map();
  for (JsMethodMirror method in methods) {
    if (method.isConstructor) {
      result[method.simpleName] = method;
    }
  }
  return result;
}

Map<Symbol, MethodMirror> filterGetters(List<MethodMirror> methods,
                                        Map<Symbol, VariableMirror> fields) {
  var result = new Map();
  for (JsMethodMirror method in methods) {
    if (method.isGetter) {

      // TODO(ahe): This is a hack to remove getters corresponding to a field.
      if (fields[method.simpleName] != null) continue;

      result[method.simpleName] = method;
    }
  }
  return result;
}

Map<Symbol, MethodMirror> filterSetters(List<MethodMirror> methods,
                                        Map<Symbol, VariableMirror> fields) {
  var result = new Map();
  for (JsMethodMirror method in methods) {
    if (method.isSetter) {

      // TODO(ahe): This is a hack to remove setters corresponding to a field.
      String name = n(method.simpleName);
      name = name.substring(0, name.length - 1); // Remove '='.
      if (fields[s(name)] != null) continue;

      result[method.simpleName] = method;
    }
  }
  return result;
}

Map<Symbol, Mirror> filterMembers(List<MethodMirror> methods,
                                  Map<Symbol, VariableMirror> variables) {
  Map<Symbol, Mirror> result = new Map.from(variables);
  for (JsMethodMirror method in methods) {
    if (method.isSetter) {
      String name = n(method.simpleName);
      name = name.substring(0, name.length - 1);
      // Filter-out setters corresponding to variables.
      if (result[s(name)] is VariableMirror) continue;
    }
    // Constructors aren't 'members'.
    if (method.isConstructor) continue;
    // Use putIfAbsent to filter-out getters corresponding to variables.
    result.putIfAbsent(method.simpleName, () => method);
  }
  return result;
}

int counter = 0;

ClassMirror reflectMixinApplication(mixinNames, String mangledName,
                                    var jsConstructor) {
  disableTreeShaking();
  var mixins = [];
  for (String mangledName in mixinNames) {
    mixins.add(reflectClassByMangledName(mangledName));
  }
  var it = mixins.iterator;
  it.moveNext();
  var superclass = it.current;
  while (it.moveNext()) {
    superclass = new JsMixinApplication(mangledName, jsConstructor);
  }
  return superclass;
}

class JsMixinApplication extends JsTypeMirror with JsObjectMirror
    implements JsClassMirror {
  ClassMirror _superclass;
  ClassMirror _mixin;
  Symbol _cachedSimpleName;
  String _mangledName;
  final _jsConstructor;

  JsMixinApplication(String mangledName, this._jsConstructor)
      : this._mangledName = mangledName,
        super(s(mangledName));

  String get _prettyName => 'ClassMirror';

  Symbol get simpleName {
    if (_cachedSimpleName != null) return _cachedSimpleName;
    String superName = n(superclass.qualifiedName);
    return _cachedSimpleName = (superName.contains(' with '))
        ? s('$superName, ${n(mixin.qualifiedName)}')
        : s('$superName with ${n(mixin.qualifiedName)}');
  }

  Symbol get qualifiedName => simpleName;

  ClassMirror _getTypeAtTypeInformationIndex(int index) {
    List<int> typeInformation =
        JS('List|Null', 'init.typeInformation[#]', _mangledName);
    if (typeInformation != null) {
      var type = getMetadata(typeInformation[index]);
      return typeMirrorFromRuntimeTypeRepresentation(this, type);
    }
    return null;
  }

  ClassMirror get superclass {
    if (_superclass != null) return _superclass;
    return _superclass = _getTypeAtTypeInformationIndex(0);
  }

  ClassMirror get mixin {
    if (_mixin != null) return _mixin;
    return _mixin = _getTypeAtTypeInformationIndex(1);
  }

  List<MethodMirror> _getMethodsWithOwner(DeclarationMirror owner) {
    return __mixin._getMethodsWithOwner(owner);
  }

  List<VariableMirror> _getFieldsWithOwner(DeclarationMirror owner) {
    return __mixin._getFieldsWithOwner(owner);
  }

  List<ClassMirror> _getSuperinterfacesWithOwner(DeclarationMirror owner) {
    return __mixin._getSuperinterfacesWithOwner(owner);
  }

  // TODO(ahe): Remove this method, only here to silence warning.
  get __mixin => mixin;

  Map<Symbol, Mirror> get members => __mixin.members;

  Map<Symbol, MethodMirror> get methods => __mixin.methods;

  Map<Symbol, MethodMirror> get __getters => __mixin.__getters;

  Map<Symbol, MethodMirror> get __setters => __mixin.__setters;

  Map<Symbol, VariableMirror> get __variables => __mixin.__variables;

  Map<Symbol, DeclarationMirror> get declarations => mixin.declarations;

  _asRuntimeType() => null;

  InstanceMirror invoke(
      Symbol memberName,
      List positionalArguments,
      [Map<Symbol,dynamic> namedArguments]) {
    // TODO(ahe): What receiver to use?
    throw new NoSuchMethodError(this, memberName,
                                positionalArguments, namedArguments);
  }

  _getInvokedInstance(Symbol constructorName,
                      List positionalArguments,
                      [Map<Symbol, dynamic> namedArguments]) {
    throw new NoSuchMethodError(this, constructorName,
                                positionalArguments, namedArguments);
  }

  InstanceMirror getField(Symbol fieldName) {
    // TODO(ahe): What receiver to use?
    throw new NoSuchMethodError(this, fieldName, null, null);
  }

  InstanceMirror setField(Symbol fieldName, Object arg) {
    // TODO(ahe): What receiver to use?
    throw new NoSuchMethodError(this, setterSymbol(fieldName), [arg], null);
  }

  List<ClassMirror> get superinterfaces => [mixin];

  Map<Symbol, MethodMirror> get __constructors => __mixin.__constructors;

  InstanceMirror newInstance(
      Symbol constructorName,
      List positionalArguments,
      [Map<Symbol,dynamic> namedArguments]) {
    throw new UnsupportedError(
        "Can't instantiate mixin application '${n(qualifiedName)}'");
  }

  bool get isOriginalDeclaration => true;

  ClassMirror get originalDeclaration => this;

  List<TypeVariableMirror> get typeVariables => const <TypeVariableMirror>[];

  List<TypeVariableMirror> get _typeVariables {
    List result = new List();
    List typeVariables =
        JS('JSExtendableArray|Null', '#.prototype["<>"]', _jsConstructor);
    if (typeVariables == null) return result;
    for (int i = 0; i < typeVariables.length; i++) {
      TypeVariable typeVariable = getMetadata(typeVariables[i]);
      result.add(
          new JsTypeVariableMirror(typeVariable, this, typeVariables[i]));
    }
    return new UnmodifiableListView(result);
  }

  List<TypeMirror> get _typeArguments => typeArguments;

  List<TypeMirror> get typeArguments => const <TypeMirror>[];

  // TODO(ahe): Implement this.
  Map<Symbol, MethodMirror> get instanceMembers
      => throw new UnimplementedError();

  // TODO(ahe): Implement this.
  Map<Symbol, MethodMirror> get staticMembers => throw new UnimplementedError();

  // TODO(ahe): Implement this.
  Function operator [](Symbol name) => throw new UnimplementedError();
}

abstract class JsObjectMirror implements ObjectMirror {
}

class JsInstanceMirror extends JsObjectMirror implements InstanceMirror {
  final reflectee;

  JsInstanceMirror(this.reflectee);

  bool get hasReflectee => true;

  ClassMirror get type => reflectType(reflectee.runtimeType);

  InstanceMirror invoke(Symbol memberName,
                        List positionalArguments,
                        [Map<Symbol,dynamic> namedArguments]) {
    String name = n(memberName);
    String reflectiveName;
    if (namedArguments != null && !namedArguments.isEmpty) {
      var interceptor = getInterceptor(reflectee);

      var jsFunction = JS('', '#[# + "*"]', interceptor, name);
      if (jsFunction == null) {
        // TODO(ahe): Invoke noSuchMethod.
        throw new UnimplementedNoSuchMethodError(
            'Invoking noSuchMethod with named arguments not implemented');
      }
      ReflectionInfo info = new ReflectionInfo(jsFunction);
      if (jsFunction == null) {
        // TODO(ahe): Invoke noSuchMethod.
        throw new UnimplementedNoSuchMethodError(
            'Invoking noSuchMethod with named arguments not implemented');
      }

      positionalArguments = new List.from(positionalArguments);
      // Check the number of positional arguments is valid.
      if (info.requiredParameterCount != positionalArguments.length) {
        // TODO(ahe): Invoke noSuchMethod.
        throw new UnimplementedNoSuchMethodError(
            'Invoking noSuchMethod with named arguments not implemented');
      }
      var defaultArguments = new Map();
      for (int i = 0; i < info.optionalParameterCount; i++) {
        var parameterName = info.parameterName(i + info.requiredParameterCount);
        var defaultValue =
            getMetadata(info.defaultValue(i + info.requiredParameterCount));
        defaultArguments[parameterName] = defaultValue;
      }
      namedArguments.forEach((Symbol symbol, value) {
        String parameter = n(symbol);
        if (defaultArguments.containsKey(parameter)) {
          defaultArguments[parameter] = value;
        } else {
          // Extraneous named argument.
          // TODO(ahe): Invoke noSuchMethod.
          throw new UnimplementedNoSuchMethodError(
              'Invoking noSuchMethod with named arguments not implemented');
        }
      });
      positionalArguments.addAll(defaultArguments.values);
      // TODO(ahe): Handle intercepted methods.
      return reflect(
          JS('', '#.apply(#, #)', jsFunction, reflectee, positionalArguments));
    } else {
      reflectiveName =
          JS('String', '# + ":" + # + ":0"', name, positionalArguments.length);
    }
    // We can safely pass positionalArguments to _invoke as it will wrap it in
    // a JSArray if needed.
    return _invoke(memberName, JSInvocationMirror.METHOD, reflectiveName,
                   positionalArguments);
  }

  InstanceMirror _invoke(Symbol name,
                         int type,
                         String reflectiveName,
                         List arguments) {
    String cacheName = Primitives.mirrorInvokeCacheName;
    var cache = JS('', r'#.constructor[#]', reflectee, cacheName);
    if (cache == null) {
      cache = JsCache.allocate();
      JS('void', r'#.constructor[#] = #', reflectee, cacheName, cache);
    }
    var cacheEntry = JsCache.fetch(cache, reflectiveName);
    var result;
    Invocation invocation;
    if (cacheEntry == null) {
      disableTreeShaking();
      String mangledName = reflectiveNames[reflectiveName];
      List<String> argumentNames = const [];
      if (type == JSInvocationMirror.METHOD) {
        // Note: [argumentNames] are not what the user actually provided, it is
        // always all the named paramters.
        argumentNames = reflectiveName.split(':').skip(3).toList();
      }

      // TODO(ahe): We don't need to create an invocation mirror here. The
      // logic from JSInvocationMirror.getCachedInvocation could easily be
      // inlined here.
      invocation = createUnmangledInvocationMirror(
          name, mangledName, type, arguments, argumentNames);

      cacheEntry =
          JSInvocationMirror.getCachedInvocation(invocation, reflectee);
      JsCache.update(cache, reflectiveName, cacheEntry);
    }
    if (cacheEntry.isNoSuchMethod) {
      if (invocation == null) {
        String mangledName = reflectiveNames[reflectiveName];
        // TODO(ahe): Get the argument names.
        List<String> argumentNames = [];
        invocation = createUnmangledInvocationMirror(
            name, mangledName, type, arguments, argumentNames);
      }
      return reflect(cacheEntry.invokeOn(reflectee, invocation));
    } else {
      return reflect(cacheEntry.invokeOn(reflectee, arguments));
    }
  }

  InstanceMirror setField(Symbol fieldName, Object arg) {
    String reflectiveName = '${n(fieldName)}=';
    _invoke(
        s(reflectiveName), JSInvocationMirror.SETTER, reflectiveName, [arg]);
    return reflect(arg);
  }

  InstanceMirror getField(Symbol fieldName) {
    String reflectiveName = n(fieldName);
    return _invoke(fieldName, JSInvocationMirror.GETTER, reflectiveName, []);
  }

  delegate(Invocation invocation) {
    return JSInvocationMirror.invokeFromMirror(invocation, reflectee);
  }

  operator ==(other) {
    return other is JsInstanceMirror &&
           identical(reflectee, other.reflectee);
  }

  int get hashCode {
    // Avoid hash collisions with the reflectee. This constant is in Smi range
    // and happens to be the inner padding from RFC 2104.
    return identityHashCode(reflectee) ^ 0x36363636;
  }

  String toString() => 'InstanceMirror on ${Error.safeToString(reflectee)}';

  // TODO(ahe): Remove this method from the API.
  MirrorSystem get mirrors => currentJsMirrorSystem;

  // TODO(ahe): Implement this method.
  Function operator [](Symbol name) => throw new UnimplementedError();
}

/**
 * ClassMirror for generic classes where the type parameters are bound.
 *
 * [typeArguments] will return a list of the type arguments, in constrast
 * to JsCLassMirror that returns an empty list since it represents original
 * declarations and classes that are not generic.
 */
class JsTypeBoundClassMirror extends JsDeclarationMirror
    implements JsClassMirror {
  final JsClassMirror _class;

  /**
   * When instantiated this field will hold a string representing the list of
   * type arguments for the class, i.e. what is inside the outermost angle
   * brackets. Then, when get typeArguments is called the first time, the string
   * is parsed into the actual list of TypeMirrors, and stored in
   * [_cachedTypeArguments]. Due to type substitution of, for instance,
   * superclasses the mangled name of the class and hence this string is needed
   * after [_cachedTypeArguments] has been computed.
   *
   * If an integer is encountered as a type argument, it represents the type
   * variable at the corresponding entry in [emitter.globalMetadata].
   */
  String _typeArgumentsString;

  UnmodifiableListView<TypeMirror> _cachedTypeArguments;
  UnmodifiableMapView<Symbol, DeclarationMirror> _cachedDeclarations;
  UnmodifiableMapView<Symbol, DeclarationMirror> _cachedMembers;
  UnmodifiableMapView<Symbol, MethodMirror> _cachedConstructors;
  Map<Symbol, VariableMirror> _cachedVariables;
  Map<Symbol, MethodMirror> _cachedGetters;
  Map<Symbol, MethodMirror> _cachedSetters;
  Map<Symbol, MethodMirror> _cachedMethodsMap;
  List<JsMethodMirror> _cachedMethods;
  ClassMirror _superclass;
  List<ClassMirror> _cachedSuperinterfaces;

  JsTypeBoundClassMirror(JsClassMirror originalDeclaration,
                         this._typeArgumentsString)
      : _class = originalDeclaration,
        super(originalDeclaration.simpleName);

  String get _prettyName => 'ClassMirror';
  String get _mangledName {
    for (TypeMirror typeArgument in typeArguments) {
      if (typeArgument != JsMirrorSystem._dynamicType) {
        return '${_class._mangledName}<$_typeArgumentsString>';
      }
    }
    // When all type arguments are dynamic, the canonical representation is to
    // drop them.
    return _class._mangledName;
  }

  List<TypeVariableMirror> get typeVariables => _class.typeVariables;

  List<TypeVariableMirror> get _typeVariables => _class._typeVariables;

  List<TypeMirror> get typeArguments {
    if (_class is JsMixinApplication) return const <TypeMirror>[];
    return _typeArguments;
  }

  List<TypeMirror> get _typeArguments {
    if (_cachedTypeArguments != null) return _cachedTypeArguments;
    List result = new List();

    addTypeArgument(String typeArgument) {
      int parsedIndex = int.parse(typeArgument, onError: (_) => -1);
      if (parsedIndex == -1) {
        result.add(reflectClassByMangledName(typeArgument.trim()));
      } else {
        TypeVariable typeVariable = getMetadata(parsedIndex);
        TypeMirror owner = reflectClass(typeVariable.owner);
        TypeVariableMirror typeMirror =
            new JsTypeVariableMirror(typeVariable, owner, parsedIndex);
        result.add(typeMirror);
      }
    }

    if (_typeArgumentsString.indexOf('<') == -1) {
      _typeArgumentsString.split(',').forEach((t) => addTypeArgument(t));
    } else {
      int level = 0;
      String currentTypeArgument = '';

      for (int i = 0; i < _typeArgumentsString.length; i++) {
        var character = _typeArgumentsString[i];
        if (character == ' ') {
          continue;
        } else if (character == '<') {
          currentTypeArgument += character;
          level++;
        } else if (character == '>') {
          currentTypeArgument += character;
          level--;
        } else if (character == ',') {
          if (level > 0) {
            currentTypeArgument += character;
          } else {
            addTypeArgument(currentTypeArgument);
            currentTypeArgument = '';
          }
        } else {
          currentTypeArgument += character;
        }
      }
      addTypeArgument(currentTypeArgument);
    }
    return _cachedTypeArguments = new UnmodifiableListView(result);
  }

  List<MethodMirror> _getMethodsWithOwner(DeclarationMirror owner) {
   return _class._getMethodsWithOwner(owner);
  }

  List<VariableMirror> _getFieldsWithOwner(DeclarationMirror owner) {
    return _class._getFieldsWithOwner(owner);
  }

  List<ClassMirror> _getSuperinterfacesWithOwner(DeclarationMirror owner) {
    return _class._getSuperinterfacesWithOwner(owner);
  }

  _getInvokedInstance(Symbol constructorName,
                      List positionalArguments,
                      [Map<Symbol, dynamic> namedArguments]) {
    return _class._getInvokedInstance(constructorName,
                                      positionalArguments,
                                      namedArguments);
  }

  List<JsMethodMirror> get _methods {
    if (_cachedMethods != null) return _cachedMethods;
    return _cachedMethods =_getMethodsWithOwner(this);
  }

  Map<Symbol, MethodMirror> get __methods {
    if (_cachedMethodsMap != null) return _cachedMethodsMap;
    return _cachedMethodsMap = new UnmodifiableMapView<Symbol, MethodMirror>(
        filterMethods(_methods));
  }

  Map<Symbol, MethodMirror> get __constructors {
    if (_cachedConstructors != null) return _cachedConstructors;
    return _cachedConstructors =
        new UnmodifiableMapView<Symbol, MethodMirror>(
            filterConstructors(_methods));
  }

  Map<Symbol, MethodMirror> get __getters {
    if (_cachedGetters != null) return _cachedGetters;
    return _cachedGetters = new UnmodifiableMapView<Symbol, MethodMirror>(
        filterGetters(_methods, __variables));
  }

  Map<Symbol, MethodMirror> get __setters {
    if (_cachedSetters != null) return _cachedSetters;
    return _cachedSetters = new UnmodifiableMapView<Symbol, MethodMirror>(
        filterSetters(_methods, __variables));
  }

  Map<Symbol, VariableMirror> get __variables {
    if (_cachedVariables != null) return _cachedVariables;
    var result = new Map();
    for (JsVariableMirror mirror in _getFieldsWithOwner(this)) {
      result[mirror.simpleName] = mirror;
    }
    return _cachedVariables =
        new UnmodifiableMapView<Symbol, VariableMirror>(result);
  }

  Map<Symbol, DeclarationMirror> get __members {
    if (_cachedMembers != null) return _cachedMembers;
    return _cachedMembers = new UnmodifiableMapView<Symbol, DeclarationMirror>(
        filterMembers(_methods, __variables));
  }

  Map<Symbol, DeclarationMirror> get declarations {
    if (_cachedDeclarations != null) return _cachedDeclarations;
    Map<Symbol, DeclarationMirror> result =
        new Map<Symbol, DeclarationMirror>();
    result.addAll(__members);
    result.addAll(__constructors);
    typeVariables.forEach((tv) => result[tv.simpleName] = tv);
    return _cachedDeclarations =
        new UnmodifiableMapView<Symbol, DeclarationMirror>(result);
  }

  InstanceMirror setField(Symbol fieldName, Object arg) {
    return _class.setField(fieldName, arg);
  }

  InstanceMirror getField(Symbol fieldName) => _class.getField(fieldName);

  InstanceMirror newInstance(Symbol constructorName,
                             List positionalArguments,
                             [Map<Symbol, dynamic> namedArguments]) {
    var instance = _getInvokedInstance(constructorName,
                                      positionalArguments,
                                      namedArguments);
    return reflect(setRuntimeTypeInfo(
        instance, typeArguments.map((t) => t._asRuntimeType()).toList()));
  }

  _asRuntimeType() {
    return [_jsConstructor].addAll(
        typeArguments.map((t) => t._asRuntimeType()));
  }

  JsLibraryMirror get owner => _class.owner;

  List<InstanceMirror> get metadata => _class.metadata;

  ClassMirror get superclass {

    if (_superclass != null) return _superclass;
    List<int> typeInformation =
        JS('List|Null', 'init.typeInformation[#]', _class._mangledName);
    assert(typeInformation != null);
    var type = getMetadata(typeInformation[0]);
    return _superclass = typeMirrorFromRuntimeTypeRepresentation(this, type);
  }

  InstanceMirror invoke(Symbol memberName,
                        List positionalArguments,
                        [Map<Symbol,dynamic> namedArguments]) {
    return _class.invoke(memberName, positionalArguments, namedArguments);
  }
  ClassMirror get mixin {
    String name = JS('String', '#.prototype[""]', _class._jsConstructor);
    if (name.contains('+')) {
      var mixin = _getTypeAtTypeInformationIndex(1);
      return mixin;
    }
  }

  get _jsConstructor {
    return _class._jsConstructor;
  }

  ClassMirror _getTypeAtTypeInformationIndex(int index) {
    List<int> typeInformation =
        JS('List|Null', 'init.typeInformation[#]', _class._mangledName);
    if (typeInformation != null) {
      var type = getMetadata(typeInformation[index]);
      return typeMirrorFromRuntimeTypeRepresentation(this, type);
    }
    return null;
  }

  bool get isOriginalDeclaration => false;

  ClassMirror get originalDeclaration => _class;

  List<ClassMirror> get superinterfaces {
    if (_cachedSuperinterfaces != null) return _cachedSuperinterfaces;
    return _cachedSuperinterfaces = _getSuperinterfacesWithOwner(this);
  }

  bool get isPrivate => _class.isPrivate;

  bool get isTopLevel => _class.isTopLevel;

  SourceLocation get location => _class.location;

  Symbol get qualifiedName => _class.qualifiedName;

  bool get hasReflectedType => true;

  Type get reflectedType => createRuntimeType(_mangledName);

  Symbol get simpleName => _class.simpleName;

  // TODO(ahe): Implement this.
  Map<Symbol, MethodMirror> get instanceMembers
      => throw new UnimplementedError();

  // TODO(ahe): Implement this.
  Map<Symbol, MethodMirror> get staticMembers => throw new UnimplementedError();

  // TODO(ahe): Implement this.
  Function operator [](Symbol name) => throw new UnimplementedError();
}

class JsClassDeclarationMirror extends JsTypeMirror with JsObjectMirror
    implements JsClassMirror {
  final String _mangledName;
  final _jsConstructorOrInterceptor;
  final String _fieldsDescriptor;
  final List _fieldsMetadata;
  final _jsConstructorCache = JsCache.allocate();
  List _metadata;
  ClassMirror _superclass;
  List<JsMethodMirror> _cachedMethods;
  List<VariableMirror> _cachedFields;
  UnmodifiableMapView<Symbol, MethodMirror> _cachedConstructors;
  UnmodifiableMapView<Symbol, MethodMirror> _cachedMethodsMap;
  UnmodifiableMapView<Symbol, MethodMirror> _cachedGetters;
  UnmodifiableMapView<Symbol, MethodMirror> _cachedSetters;
  UnmodifiableMapView<Symbol, VariableMirror> _cachedVariables;
  UnmodifiableMapView<Symbol, Mirror> _cachedMembers;
  UnmodifiableMapView<Symbol, DeclarationMirror> _cachedDeclarations;
  UnmodifiableListView<InstanceMirror> _cachedMetadata;
  UnmodifiableListView<ClassMirror> _cachedSuperinterfaces;
  UnmodifiableListView<TypeVariableMirror> _cachedTypeVariables;

  // Set as side-effect of accessing JsLibraryMirror.classes.
  JsLibraryMirror _owner;

  JsClassDeclarationMirror(Symbol simpleName,
                this._mangledName,
                this._jsConstructorOrInterceptor,
                this._fieldsDescriptor,
                this._fieldsMetadata)
      : super(simpleName);

  String get _prettyName => 'ClassMirror';

  get _jsConstructor {
    if (_jsConstructorOrInterceptor is Interceptor) {
      return JS('', '#.constructor', _jsConstructorOrInterceptor);
    } else {
      return _jsConstructorOrInterceptor;
    }
  }

  Map<Symbol, MethodMirror> get __constructors {
    if (_cachedConstructors != null) return _cachedConstructors;
    return _cachedConstructors =
        new UnmodifiableMapView<Symbol, MethodMirror>(
            filterConstructors(_methods));
  }

  _asRuntimeType() {
    if (typeVariables.isEmpty)  return _jsConstructor;
    var type = [_jsConstructor];
    for (int i = 0; i < typeVariables.length; i ++) {
      type.add(JsMirrorSystem._dynamicType._asRuntimeType);
    }
    return type;
  }

  List<JsMethodMirror> _getMethodsWithOwner(DeclarationMirror methodOwner) {
    var prototype = JS('', '#.prototype', _jsConstructor);
    List<String> keys = extractKeys(prototype);
    var result = <JsMethodMirror>[];
    for (String key in keys) {
      if (isReflectiveDataInPrototype(key)) continue;
      String simpleName = mangledNames[key];
      // [simpleName] can be null if [key] represents an implementation
      // detail, for example, a bailout method, or runtime type support.
      // It might also be null if the user has limited what is reified for
      // reflection with metadata.
      if (simpleName == null) continue;
      var function = JS('', '#[#]', prototype, key);
      var mirror =
          new JsMethodMirror.fromUnmangledName(
              simpleName, function, false, false);
      result.add(mirror);
      mirror._owner = methodOwner;
    }

    keys = extractKeys(JS('', 'init.statics[#]', _mangledName));
    for (String mangledName in keys) {
      if (isReflectiveDataInPrototype(mangledName)) continue;
      String unmangledName = mangledName;
      var jsFunction = JS('', '#[#]', owner._globalObject, mangledName);

      bool isConstructor = false;
      if (hasReflectableProperty(jsFunction)) {
        String reflectionName =
            JS('String|Null', r'#.$reflectionName', jsFunction);
        if (reflectionName == null) continue;
        isConstructor = reflectionName.startsWith('new ');
        if (isConstructor) {
          reflectionName = reflectionName.substring(4).replaceAll(r'$', '.');
        }
        unmangledName = reflectionName;
      } else {
        continue;
      }
      bool isStatic = !isConstructor; // Constructors are not static.
      JsMethodMirror mirror =
          new JsMethodMirror.fromUnmangledName(
              unmangledName, jsFunction, isStatic, isConstructor);
      result.add(mirror);
      mirror._owner = methodOwner;
    }

    return result;
  }

  List<JsMethodMirror> get _methods {
    if (_cachedMethods != null) return _cachedMethods;
    return _cachedMethods = _getMethodsWithOwner(this);
  }

  List<VariableMirror> _getFieldsWithOwner(DeclarationMirror fieldOwner) {
    var result = <VariableMirror>[];

    var instanceFieldSpecfication = _fieldsDescriptor.split(';')[1];
    if (_fieldsMetadata != null) {
      instanceFieldSpecfication =
          [instanceFieldSpecfication]..addAll(_fieldsMetadata);
    }
    parseCompactFieldSpecification(
        fieldOwner, instanceFieldSpecfication, false, result);

    var staticDescriptor = JS('', 'init.statics[#]', _mangledName);
    if (staticDescriptor != null) {
      parseCompactFieldSpecification(
          fieldOwner, JS('', '#[""]', staticDescriptor), true, result);
    }
    return result;
  }

  List<VariableMirror> get _fields {
    if (_cachedFields != null) return _cachedFields;
    return _cachedFields = _getFieldsWithOwner(this);
  }

  Map<Symbol, MethodMirror> get __methods {
    if (_cachedMethodsMap != null) return _cachedMethodsMap;
    return _cachedMethodsMap =
        new UnmodifiableMapView<Symbol, MethodMirror>(filterMethods(_methods));
  }

  Map<Symbol, MethodMirror> get __getters {
    if (_cachedGetters != null) return _cachedGetters;
    return _cachedGetters = new UnmodifiableMapView<Symbol, MethodMirror>(
        filterGetters(_methods, __variables));
  }

  Map<Symbol, MethodMirror> get __setters {
    if (_cachedSetters != null) return _cachedSetters;
    return _cachedSetters = new UnmodifiableMapView<Symbol, MethodMirror>(
        filterSetters(_methods, __variables));
  }

  Map<Symbol, VariableMirror> get __variables {
    if (_cachedVariables != null) return _cachedVariables;
    var result = new Map();
    for (JsVariableMirror mirror in _fields) {
      result[mirror.simpleName] = mirror;
    }
    return _cachedVariables =
        new UnmodifiableMapView<Symbol, VariableMirror>(result);
  }

  Map<Symbol, Mirror> get __members {
    if (_cachedMembers != null) return _cachedMembers;
    return _cachedMembers = new UnmodifiableMapView<Symbol, Mirror>(
        filterMembers(_methods, __variables));
  }

  Map<Symbol, DeclarationMirror> get declarations {
    if (_cachedDeclarations != null) return _cachedDeclarations;
    var result = new Map<Symbol, DeclarationMirror>();
    addToResult(Symbol key, Mirror value) {
      result[key] = value;
    }
    __members.forEach(addToResult);
    __constructors.forEach(addToResult);
    typeVariables.forEach((tv) => result[tv.simpleName] = tv);
    return _cachedDeclarations =
        new UnmodifiableMapView<Symbol, DeclarationMirror>(result);
  }

  InstanceMirror setField(Symbol fieldName, Object arg) {
    JsVariableMirror mirror = __variables[fieldName];
    if (mirror != null && mirror.isStatic && !mirror.isFinal) {
      // '$' (JS_CURRENT_ISOLATE()) stores state which is stored directly, so
      // we shouldn't use [JsLibraryMirror._globalObject] here.
      String jsName = mirror._jsName;
      if (!JS('bool', '# in #', jsName, JS_CURRENT_ISOLATE())) {
        throw new RuntimeError('Cannot find "$jsName" in current isolate.');
      }
      JS('void', '#[#] = #', JS_CURRENT_ISOLATE(), jsName, arg);
      return reflect(arg);
    }
    // TODO(ahe): What receiver to use?
    throw new NoSuchMethodError(this, setterSymbol(fieldName), [arg], null);
  }

  InstanceMirror getField(Symbol fieldName) {
    JsVariableMirror mirror = __variables[fieldName];
    if (mirror != null && mirror.isStatic) {
      String jsName = mirror._jsName;
      // '$' (JS_CURRENT_ISOLATE()) stores state which is read directly, so
      // we shouldn't use [JsLibraryMirror._globalObject] here.
      if (!JS('bool', '# in #', jsName, JS_CURRENT_ISOLATE())) {
        throw new RuntimeError('Cannot find "$jsName" in current isolate.');
      }
      if (JS('bool', '# in init.lazies', jsName)) {
        String getterName = JS('String', 'init.lazies[#]', jsName);
        return reflect(JS('', '#[#]()', JS_CURRENT_ISOLATE(), getterName));
      } else {
        return reflect(JS('', '#[#]', JS_CURRENT_ISOLATE(), jsName));
      }
    }
    // TODO(ahe): What receiver to use?
    throw new NoSuchMethodError(this, fieldName, null, null);
  }

  _getInvokedInstance(Symbol constructorName,
                      List positionalArguments,
                      [Map<Symbol, dynamic> namedArguments]) {
     if (namedArguments != null && !namedArguments.isEmpty) {
       throw new UnsupportedError('Named arguments are not implemented.');
     }
     JsMethodMirror mirror =
         JsCache.fetch(_jsConstructorCache, n(constructorName));
     if (mirror == null) {
       mirror = __constructors.values.firstWhere(
           (m) => m.constructorName == constructorName,
           orElse: () {
             // TODO(ahe): What receiver to use?
             throw new NoSuchMethodError(
                 this, constructorName, positionalArguments, namedArguments);
           });
       JsCache.update(_jsConstructorCache, n(constructorName), mirror);
     }
     return mirror._invoke(positionalArguments, namedArguments);
   }

  InstanceMirror newInstance(Symbol constructorName,
                             List positionalArguments,
                             [Map<Symbol, dynamic> namedArguments]) {
    return reflect(_getInvokedInstance(constructorName,
                                       positionalArguments,
                                       namedArguments));
  }

  JsLibraryMirror get owner {
    if (_owner == null) {
      if (_jsConstructorOrInterceptor is Interceptor) {
        _owner = reflectType(Object).owner;
      } else {
        for (var list in JsMirrorSystem.librariesByName.values) {
          for (JsLibraryMirror library in list) {
            // This will set _owner field on all clasess as a side
            // effect.  This gives us a fast path to reflect on a
            // class without parsing reflection data.
            library.__classes;
          }
        }
      }
      if (_owner == null) {
        throw new StateError('Class "${n(simpleName)}" has no owner');
      }
    }
    return _owner;
  }

  List<InstanceMirror> get metadata {
    if (_cachedMetadata != null) return _cachedMetadata;
    if (_metadata == null) {
      _metadata = extractMetadata(JS('', '#.prototype', _jsConstructor));
    }
    return _cachedMetadata =
        new UnmodifiableListView<InstanceMirror>(_metadata.map(reflect));
  }

  ClassMirror get superclass {
    if (_superclass == null) {
      List<int> typeInformation =
          JS('List|Null', 'init.typeInformation[#]', _mangledName);
      if (typeInformation != null) {
        var type = getMetadata(typeInformation[0]);
        _superclass = typeMirrorFromRuntimeTypeRepresentation(this, type);
      } else {
        var superclassName = _fieldsDescriptor.split(';')[0];
        // TODO(zarah): Remove special handing of mixins.
        var mixins = superclassName.split('+');
        if (mixins.length > 1) {
          if (mixins.length != 2) {
            throw new RuntimeError('Strange mixin: $_fieldsDescriptor');
          }
          _superclass = reflectClassByMangledName(mixins[0]);
        } else {
          // Use _superclass == this to represent class with no superclass
          // (Object).
          _superclass = (superclassName == '')
              ? this : reflectClassByMangledName(superclassName);
          }
        }
      }
    return _superclass == this ? null : _superclass;
  }

  InstanceMirror invoke(Symbol memberName,
                        List positionalArguments,
                        [Map<Symbol,dynamic> namedArguments]) {
    // Mirror API gotcha: Calling [invoke] on a ClassMirror means invoke a
    // static method.

    if (namedArguments != null && !namedArguments.isEmpty) {
      throw new UnsupportedError('Named arguments are not implemented.');
    }
    JsMethodMirror mirror = __methods[memberName];
    if (mirror == null || !mirror.isStatic) {
      // TODO(ahe): What receiver to use?
      throw new NoSuchMethodError(
          this, memberName, positionalArguments, namedArguments);
    }
    if (!mirror.canInvokeReflectively()) {
      throwInvalidReflectionError(n(memberName));
    }
    return reflect(mirror._invoke(positionalArguments, namedArguments));
  }

  bool get isOriginalDeclaration => true;

  ClassMirror get originalDeclaration => this;

  List<ClassMirror> _getSuperinterfacesWithOwner(DeclarationMirror owner) {
    List<int> typeInformation =
        JS('List|Null', 'init.typeInformation[#]', _mangledName);
    List<ClassMirror> result = const <ClassMirror>[];
    if (typeInformation != null) {
      ClassMirror lookupType(int i) {
        var type = getMetadata(i);
        return typeMirrorFromRuntimeTypeRepresentation(owner, type);
      }

      //We skip the first since it is the supertype.
      result = typeInformation.skip(1).map(lookupType).toList();
    }

    return new UnmodifiableListView<ClassMirror>(result);
  }

  List<ClassMirror> get superinterfaces {
    if (_cachedSuperinterfaces != null) return _cachedSuperinterfaces;
    return _cachedSuperinterfaces = _getSuperinterfacesWithOwner(this);
  }

  List<TypeVariableMirror> get typeVariables => _typeVariables;

  List<TypeVariableMirror> get _typeVariables {
   if (_cachedTypeVariables != null) return _cachedTypeVariables;
   List result = new List();
   List typeVariables =
        JS('JSExtendableArray|Null', '#.prototype["<>"]', _jsConstructor);
    if (typeVariables == null) return result;
    for (int i = 0; i < typeVariables.length; i++) {
      TypeVariable typeVariable = getMetadata(typeVariables[i]);
      result.add(new JsTypeVariableMirror(typeVariable, this,
                                          typeVariables[i]));
    }
    return _cachedTypeVariables = new UnmodifiableListView(result);
  }

  List<TypeMirror> get _typeArguments => typeArguments;

  List<TypeMirror> get typeArguments => const <TypeMirror>[];

  bool get hasReflectedType => typeVariables.length == 0;

  Type get reflectedType {
    if (!hasReflectedType) {
      throw new UnsupportedError(
          "Declarations of generics have no reflected type");
    }
    return createRuntimeType(_mangledName);
  }

  // TODO(ahe): Implement this.
  Map<Symbol, MethodMirror> get instanceMembers
      => throw new UnimplementedError();

  // TODO(ahe): Implement this.
  Map<Symbol, MethodMirror> get staticMembers => throw new UnimplementedError();

  // TODO(ahe): Implement this.
  ClassMirror get mixin => throw new UnimplementedError();

  // TODO(ahe): Implement this.
  Function operator [](Symbol name) => throw new UnimplementedError();
}

class JsVariableMirror extends JsDeclarationMirror implements VariableMirror {

  // TODO(ahe): The values in these fields are virtually untested.
  final String _jsName;
  final bool isFinal;
  final bool isStatic;
  final _metadataFunction;
  final DeclarationMirror _owner;
  final int _type;
  List _metadata;

  JsVariableMirror(Symbol simpleName,
                   this._jsName,
                   this._type,
                   this.isFinal,
                   this.isStatic,
                   this._metadataFunction,
                   this._owner)
      : super(simpleName);

  factory JsVariableMirror.from(String descriptor,
                                metadataFunction,
                                JsDeclarationMirror owner,
                                bool isStatic) {
    List<String> fieldInformation = descriptor.split('-');
    if (fieldInformation.length == 1) {
      // The field is not available for reflection.
      // TODO(ahe): Should return an unreflectable field.
      return null;
    }

    String field = fieldInformation[0];
    int length = field.length;
    var code = fieldCode(field.codeUnitAt(length - 1));
    bool isFinal = false;
    if (code == 0) return null; // Inherited field.
    bool hasGetter = (code & 3) != 0;
    bool hasSetter = (code >> 2) != 0;
    isFinal = !hasSetter;
    length--;
    String jsName;
    String accessorName = jsName = field.substring(0, length);
    int divider = field.indexOf(':');
    if (divider > 0) {
      accessorName = accessorName.substring(0, divider);
      jsName = field.substring(divider + 1);
    }
    var unmangledName;
    if (isStatic) {
      unmangledName = mangledGlobalNames[accessorName];
    } else {
      String getterPrefix = JS_GET_NAME('GETTER_PREFIX');
      unmangledName = mangledNames['$getterPrefix$accessorName'];
    }
    if (unmangledName == null) unmangledName = accessorName;
    if (!hasSetter) {
      // TODO(ahe): This is a hack to handle checked setters in checked mode.
      var setterName = s('$unmangledName=');
      for (JsMethodMirror method in owner._methods) {
        if (method.simpleName == setterName) {
          isFinal = false;
          break;
        }
      }
    }
    int type = int.parse(fieldInformation[1]);
    return new JsVariableMirror(s(unmangledName),
                                jsName,
                                type,
                                isFinal,
                                isStatic,
                                metadataFunction,
                                owner);
  }

  String get _prettyName => 'VariableMirror';

  TypeMirror get type {
    return typeMirrorFromRuntimeTypeRepresentation(owner, getMetadata(_type));
  }

  DeclarationMirror get owner => _owner;

  List<InstanceMirror> get metadata {
    preserveMetadata();
    if (_metadata == null) {
      _metadata = (_metadataFunction == null)
          ? const [] : JS('', '#()', _metadataFunction);
    }
    return _metadata.map(reflect).toList();
  }

  static int fieldCode(int code) {
    if (code >= 60 && code <= 64) return code - 59;
    if (code >= 123 && code <= 126) return code - 117;
    if (code >= 37 && code <= 43) return code - 27;
    return 0;
  }

  _getField(JsMirror receiver) => receiver._loadField(_jsName);

  void _setField(JsMirror receiver, Object arg) {
    if (isFinal) {
      throw new NoSuchMethodError(this, setterSymbol(simpleName), [arg], null);
    }
    receiver._storeField(_jsName, arg);
  }

  // TODO(ahe): Implement this method.
  bool get isConst => throw new UnimplementedError();
}

class JsClosureMirror extends JsInstanceMirror implements ClosureMirror {
  JsClosureMirror(reflectee)
      : super(reflectee);

  MethodMirror get function {
    String cacheName = Primitives.mirrorFunctionCacheName;
    JsMethodMirror cachedFunction;
    // TODO(ahe): Restore caching.
    //= JS('JsMethodMirror|Null', r'#.constructor[#]', reflectee, cacheName);
    if (cachedFunction != null) return cachedFunction;
    disableTreeShaking();
    // TODO(ahe): What about optional parameters (named or not).
    var extractCallName = JS('', r'''
function(reflectee) {
  for (var property in reflectee) {
    if ("call$" == property.substring(0, 5)) return property;
  }
  return null;
}
''');
    String callName = JS('String|Null', '#(#)', extractCallName, reflectee);
    if (callName == null) {
      throw new RuntimeError('Cannot find callName on "$reflectee"');
    }
    int parameterCount = int.parse(callName.split(r'$')[1]);
    if (reflectee is BoundClosure) {
      var target = BoundClosure.targetOf(reflectee);
      var self = BoundClosure.selfOf(reflectee);
      var name = mangledNames[BoundClosure.nameOf(reflectee)];
      if (name == null) {
        throwInvalidReflectionError(name);
      }
      cachedFunction = new JsMethodMirror.fromUnmangledName(
          name, target, false, false);
    } else {
      bool isStatic = true; // TODO(ahe): Compute isStatic correctly.
      var jsFunction = JS('', '#[#]', reflectee, callName);
      cachedFunction = new JsMethodMirror(
          s(callName), jsFunction, parameterCount,
          false, false, isStatic, false, false);
    }
    JS('void', r'#.constructor[#] = #', reflectee, cacheName, cachedFunction);
    return cachedFunction;
  }

  InstanceMirror apply(List positionalArguments,
                       [Map<Symbol, dynamic> namedArguments]) {
    return reflect(
        Function.apply(reflectee, positionalArguments, namedArguments));
  }

  String toString() => "ClosureMirror on '${Error.safeToString(reflectee)}'";

  // TODO(ahe): Implement this method.
  String get source => throw new UnimplementedError();

  // TODO(ahe): Implement this method.
  InstanceMirror findInContext(Symbol name) {
    throw new UnsupportedError("ClosureMirror.findInContext not yet supported");
  }

  // TODO(ahe): Implement this method.
  Function operator [](Symbol name) => throw new UnimplementedError();
}

class JsMethodMirror extends JsDeclarationMirror implements MethodMirror {
  final _jsFunction;
  final int _parameterCount;
  final bool isGetter;
  final bool isSetter;
  final bool isStatic;
  final bool isConstructor;
  final bool isOperator;
  DeclarationMirror _owner;
  List _metadata;
  TypeMirror _returnType;
  UnmodifiableListView<ParameterMirror> _parameters;

  JsMethodMirror(Symbol simpleName,
                 this._jsFunction,
                 this._parameterCount,
                 this.isGetter,
                 this.isSetter,
                 this.isStatic,
                 this.isConstructor,
                 this.isOperator)
      : super(simpleName);

  factory JsMethodMirror.fromUnmangledName(String name,
                                           jsFunction,
                                           bool isStatic,
                                           bool isConstructor) {
    List<String> info = name.split(':');
    name = info[0];
    bool isOperator = isOperatorName(name);
    bool isSetter = !isOperator && name.endsWith('=');
    int requiredParameterCount = 0;
    int optionalParameterCount = 0;
    bool isGetter = false;
    if (info.length == 1) {
      if (isSetter) {
        requiredParameterCount = 1;
      } else {
        isGetter = true;
        requiredParameterCount = 0;
      }
    } else {
      requiredParameterCount = int.parse(info[1]);
      optionalParameterCount = int.parse(info[2]);
    }
    return new JsMethodMirror(
        s(name), jsFunction, requiredParameterCount + optionalParameterCount,
        isGetter, isSetter, isStatic, isConstructor, isOperator);
  }

  String get _prettyName => 'MethodMirror';

  List<ParameterMirror> get parameters {
    if (_parameters != null) return _parameters;
    metadata; // Compute _parameters as a side-effect of extracting metadata.
    return _parameters;
  }

  bool canInvokeReflectively() {
    return hasReflectableProperty(_jsFunction);
  }

  DeclarationMirror get owner {
    if (_owner is! ClassMirror)
      return _owner;
   ClassMirror ownerClass = _owner;
   if (ownerClass.originalDeclaration is JsMixinApplication) {
     return ownerClass.mixin;
   }
   return _owner;
  }

  TypeMirror get returnType {
    metadata; // Compute _returnType as a side-effect of extracting metadata.
    return _returnType;
  }

  List<InstanceMirror> get metadata {
    if (_metadata == null) {
      var raw = extractMetadata(_jsFunction);
      var formals = new List(_parameterCount);
      ReflectionInfo info = new ReflectionInfo(_jsFunction);
      if (info != null) {
        assert(_parameterCount
               == info.requiredParameterCount + info.optionalParameterCount);
        var functionType = info.functionType;
        var type;
        if (functionType is int) {
          type = new JsFunctionTypeMirror(info.computeFunctionRti(null), this);
          assert(_parameterCount == type.parameters.length);
        } else if (isTopLevel) {
          type = new JsFunctionTypeMirror(info.computeFunctionRti(null), owner);
        } else {
          TypeMirror ownerType = owner;
          JsClassDeclarationMirror ownerClass = ownerType.originalDeclaration;
          type = new JsFunctionTypeMirror(
              info.computeFunctionRti(ownerClass._jsConstructorOrInterceptor),
              owner);
        }
        // Constructors aren't reified with their return type.
        if (isConstructor) {
          _returnType = owner;
        } else {
          _returnType = type.returnType;
        }
        int i = 0;
        bool isNamed = info.areOptionalParametersNamed;
        for (JsParameterMirror parameter in type.parameters) {
          var name = info.parameterName(i);
          var p;
          if (i < info.requiredParameterCount) {
            p = new JsParameterMirror(name, this, parameter._type);
          } else {
            var defaultValue = info.defaultValue(i);
            p = new JsParameterMirror(
                name, this, parameter._type,
                isOptional: true, isNamed: isNamed, defaultValue: defaultValue);
          }
          formals[i++] = p;
        }
      }
      _parameters = new UnmodifiableListView<ParameterMirror>(formals);
      _metadata = new UnmodifiableListView(raw.map(reflect));
    }
    return _metadata;
  }

  Symbol get constructorName {
    // TODO(ahe): I believe it is more appropriate to throw an exception or
    // return null.
    if (!isConstructor) return const Symbol('');
    String name = n(simpleName);
    int index = name.indexOf('.');
    if (index == -1) return const Symbol('');
    return s(name.substring(index + 1));
  }

  _invoke(List positionalArguments, Map<Symbol, dynamic> namedArguments) {
    if (namedArguments != null && !namedArguments.isEmpty) {
      throw new UnsupportedError('Named arguments are not implemented.');
    }
    if (!isStatic && !isConstructor) {
      throw new RuntimeError('Cannot invoke instance method without receiver.');
    }
    if (_parameterCount != positionalArguments.length || _jsFunction == null) {
      // TODO(ahe): What receiver to use?
      throw new NoSuchMethodError(
          owner, simpleName, positionalArguments, namedArguments);
    }
    // Using JS_CURRENT_ISOLATE() ('$') here is actually correct, although
    // _jsFunction may not be a property of '$', most static functions do not
    // care who their receiver is. But to lazy getters, it is important that
    // 'this' is '$'.
    return JS('', r'#.apply(#, #)', _jsFunction, JS_CURRENT_ISOLATE(),
              new List.from(positionalArguments));
  }

  _getField(JsMirror receiver) {
    if (isGetter) {
      return _invoke([], null);
    } else {
      // TODO(ahe): Closurize method.
      throw new UnimplementedError('getField on $receiver');
    }
  }

  _setField(JsMirror receiver, Object arg) {
    if (isSetter) {
      return _invoke([arg], null);
    } else {
      throw new NoSuchMethodError(this, setterSymbol(simpleName), [], null);
    }
  }

  // Abstract methods are tree-shaken away.
  bool get isAbstract => false;

  // TODO(ahe, 14633): This might not be true for all cases.
  bool get isSynthetic => false;

  // TODO(ahe): Test this.
  bool get isRegularMethod => !isGetter && !isSetter && !isConstructor;

  // TODO(ahe): Implement this method.
  bool get isConstConstructor => throw new UnimplementedError();

  // TODO(ahe): Implement this method.
  bool get isGenerativeConstructor => throw new UnimplementedError();

  // TODO(ahe): Implement this method.
  bool get isRedirectingConstructor => throw new UnimplementedError();

  // TODO(ahe): Implement this method.
  bool get isFactoryConstructor => throw new UnimplementedError();

  // TODO(ahe): Implement this method.
  String get source => throw new UnimplementedError();
}

class JsParameterMirror extends JsDeclarationMirror implements ParameterMirror {
  final DeclarationMirror owner;
  // A JS object representing the type.
  final _type;

  final bool isOptional;

  final bool isNamed;

  final int _defaultValue;

  JsParameterMirror(String unmangledName,
                    this.owner,
                    this._type,
                    {this.isOptional: false,
                     this.isNamed: false,
                     defaultValue})
      : _defaultValue = defaultValue,
        super(s(unmangledName));

  String get _prettyName => 'ParameterMirror';

  TypeMirror get type {
    return typeMirrorFromRuntimeTypeRepresentation(owner, _type);
  }

  // Only true for static fields, never for a parameter.
  bool get isStatic => false;

  // TODO(ahe): Implement this.
  bool get isFinal => false;

  // TODO(ahe): Implement this.
  bool get isConst => false;

  bool get hasDefaultValue => _defaultValue != null;

  get defaultValue {
    return hasDefaultValue ? reflect(getMetadata(_defaultValue)) : null;
  }

  // TODO(ahe): Implement this.
  List<InstanceMirror> get metadata => throw new UnimplementedError();
}

class JsTypedefMirror extends JsDeclarationMirror implements TypedefMirror {
  final String _mangledName;
  JsFunctionTypeMirror referent;

  JsTypedefMirror(Symbol simpleName,  this._mangledName, _typeData)
      : super(simpleName) {
    referent = new JsFunctionTypeMirror(_typeData, this);
  }

  JsFunctionTypeMirror get value => referent;

  String get _prettyName => 'TypedefMirror';

  // TODO(ahe): Implement this method.
  List<TypeVariableMirror> get typeVariables => throw new UnimplementedError();

  // TODO(ahe): Implement this method.
  List<TypeMirror> get typeArguments => throw new UnimplementedError();

  // TODO(ahe): Implement this method.
  bool get isOriginalDeclaration => throw new UnimplementedError();

  // TODO(ahe): Implement this method.
  TypeMirror get originalDeclaration => throw new UnimplementedError();

  // TODO(ahe): Implement this method.
  DeclarationMirror get owner => throw new UnimplementedError();

  // TODO(ahe): Implement this method.
  List<InstanceMirror> get metadata => throw new UnimplementedError();
}

// TODO(ahe): Remove this class when API is updated.
class BrokenClassMirror {
  bool get hasReflectedType => throw new UnimplementedError();
  Type get reflectedType => throw new UnimplementedError();
  ClassMirror get superclass => throw new UnimplementedError();
  List<ClassMirror> get superinterfaces => throw new UnimplementedError();
  Map<Symbol, DeclarationMirror> get declarations
      => throw new UnimplementedError();
  Map<Symbol, MethodMirror> get instanceMembers
      => throw new UnimplementedError();
  Map<Symbol, MethodMirror> get staticMembers => throw new UnimplementedError();
  ClassMirror get mixin => throw new UnimplementedError();
  InstanceMirror newInstance(
      Symbol constructorName,
      List positionalArguments,
      [Map<Symbol,dynamic> namedArguments]) => throw new UnimplementedError();
  Function operator [](Symbol name) => throw new UnimplementedError();
  InstanceMirror invoke(Symbol memberName,
                        List positionalArguments,
                        [Map<Symbol, dynamic> namedArguments])
      => throw new UnimplementedError();
  InstanceMirror getField(Symbol fieldName) => throw new UnimplementedError();
  InstanceMirror setField(Symbol fieldName, Object value)
      => throw new UnimplementedError();
  List<TypeVariableMirror> get typeVariables => throw new UnimplementedError();
  List<TypeMirror> get typeArguments => throw new UnimplementedError();
  TypeMirror get originalDeclaration => throw new UnimplementedError();
  Symbol get simpleName => throw new UnimplementedError();
  Symbol get qualifiedName => throw new UnimplementedError();
  bool get isPrivate => throw new UnimplementedError();
  bool get isTopLevel => throw new UnimplementedError();
  SourceLocation get location => throw new UnimplementedError();
  List<InstanceMirror> get metadata => throw new UnimplementedError();
}

class JsFunctionTypeMirror extends BrokenClassMirror
    implements FunctionTypeMirror {
  final _typeData;
  String _cachedToString;
  TypeMirror _cachedReturnType;
  UnmodifiableListView<ParameterMirror> _cachedParameters;
  DeclarationMirror owner;

  JsFunctionTypeMirror(this._typeData, this.owner);

  bool get _hasReturnType => JS('bool', '"ret" in #', _typeData);
  get _returnType => JS('', '#.ret', _typeData);

  bool get _isVoid => JS('bool', '!!#.void', _typeData);

  bool get _hasArguments => JS('bool', '"args" in #', _typeData);
  List get _arguments => JS('JSExtendableArray', '#.args', _typeData);

  bool get _hasOptionalArguments => JS('bool', '"opt" in #', _typeData);
  List get _optionalArguments => JS('JSExtendableArray', '#.opt', _typeData);

  bool get _hasNamedArguments => JS('bool', '"named" in #', _typeData);
  get _namedArguments => JS('=Object', '#.named', _typeData);
  bool get isOriginalDeclaration => true;

  TypeMirror get returnType {
    if (_cachedReturnType != null) return _cachedReturnType;
    if (_isVoid) return _cachedReturnType = JsMirrorSystem._voidType;
    if (!_hasReturnType) return _cachedReturnType = JsMirrorSystem._dynamicType;
    return _cachedReturnType =
        typeMirrorFromRuntimeTypeRepresentation(owner, _returnType);
  }

  List<ParameterMirror> get parameters {
    if (_cachedParameters != null) return _cachedParameters;
    List result = [];
    int parameterCount = 0;
    if (_hasArguments) {
      for (var type in _arguments) {
        result.add(
            new JsParameterMirror('argument${parameterCount++}', this, type));
      }
    }
    if (_hasOptionalArguments) {
      for (var type in _optionalArguments) {
        result.add(
            new JsParameterMirror('argument${parameterCount++}', this, type));
      }
    }
    if (_hasNamedArguments) {
      for (var name in extractKeys(_namedArguments)) {
        var type = JS('', '#[#]', _namedArguments, name);
        result.add(new JsParameterMirror(name, this, type));
      }
    }
    return _cachedParameters = new UnmodifiableListView<ParameterMirror>(
        result);
  }

  String toString() {
    if (_cachedToString != null) return _cachedToString;
    var s = "FunctionTypeMirror on '(";
    var sep = '';
    if (_hasArguments) {
      for (var argument in _arguments) {
        s += sep;
        s += runtimeTypeToString(argument);
        sep = ', ';
      }
    }
    if (_hasOptionalArguments) {
      s += '$sep[';
      sep = '';
      for (var argument in _optionalArguments) {
        s += sep;
        s += runtimeTypeToString(argument);
        sep = ', ';
      }
      s += ']';
    }
    if (_hasNamedArguments) {
      s += '$sep{';
      sep = '';
      for (var name in extractKeys(_namedArguments)) {
        s += sep;
        s += '$name: ';
        s += runtimeTypeToString(JS('', '#[#]', _namedArguments, name));
        sep = ', ';
      }
      s += '}';
    }
    s += ') -> ';
    if (_isVoid) {
      s += 'void';
    } else if (_hasReturnType) {
      s += runtimeTypeToString(_returnType);
    } else {
      s += 'dynamic';
    }
    return _cachedToString = "$s'";
  }

  // TODO(ahe): Implement this method.
  MethodMirror get callMethod => throw new UnimplementedError();
}

int findTypeVariableIndex(List<TypeVariableMirror> typeVariables, String name) {
  for (int i = 0; i < typeVariables.length; i++) {
    if (typeVariables[i].simpleName == s(name)) {
      return i;
    }
  }
  throw new ArgumentError('Type variable not present in list.');
}

TypeMirror typeMirrorFromRuntimeTypeRepresentation(
    DeclarationMirror owner,
    var /*int|List|JsFunction*/ type) {
  // TODO(ahe): This method might benefit from using convertRtiToRuntimeType
  // instead of working on strings.
  JsClassMirror ownerClass;
  DeclarationMirror context = owner;
  while (context != null) {
    if (context is JsClassMirror) {
      ownerClass = context;
      break;
    }
    // TODO(ahe): Get type parameters and arguments from typedefs.
    if (context is TypedefMirror) break;
    context = context.owner;
  }

  String representation;
  if (type == null) {
    return JsMirrorSystem._dynamicType;
  } else if (ownerClass == null) {
    representation = runtimeTypeToString(type);
  } else if (ownerClass.isOriginalDeclaration) {
    if (type is num) {
      // [type] represents a type variable so in the context of an original
      // declaration the corresponding type variable should be returned.
      TypeVariable typeVariable = getMetadata(type);
      List<TypeVariableMirror> typeVariables = ownerClass._typeVariables;
      int index = findTypeVariableIndex(typeVariables, typeVariable.name);
      return typeVariables[index];
    } else {
      // Nested type variables will be retrieved lazily (the integer
      // representation is kept in the string) so they are not processed here.
      representation = runtimeTypeToString(type);
    }
  } else {
    getTypeArgument(int index) {
      TypeVariable typeVariable = getMetadata(index);
      int variableIndex =
          findTypeVariableIndex(ownerClass._typeVariables, typeVariable.name);
      return ownerClass._typeArguments[variableIndex];
    }

    if (type is num) {
      // [type] represents a type variable used as type argument for example
      // the type argument of Bar: class Foo<T> extends Bar<T> {}
      TypeMirror typeArgument = getTypeArgument(type);
      if (typeArgument is JsTypeVariableMirror)
        return typeArgument;
    }
    String substituteTypeVariable(int index) {
      var typeArgument = getTypeArgument(index);
      if (typeArgument is JsTypeVariableMirror)
        return '${typeArgument._metadataIndex}';
      assert(typeArgument is JsClassDeclarationMirror ||
             typeArgument is JsTypeBoundClassMirror);
      return typeArgument._mangledName;
    }
    representation =
        runtimeTypeToString(type, onTypeVariable: substituteTypeVariable);
  }
  if (representation != null) {
    return reflectClassByMangledName(
        getMangledTypeName(createRuntimeType(representation)));
  }
  return reflectClass(Function);
}

Symbol computeQualifiedName(DeclarationMirror owner, Symbol simpleName) {
  if (owner == null) return simpleName;
  String ownerName = n(owner.qualifiedName);
  return s('$ownerName.${n(simpleName)}');
}

List extractMetadata(victim) {
  preserveMetadata();
  var metadataFunction = JS('', '#["@"]', victim);
  if (metadataFunction != null) return JS('', '#()', metadataFunction);
  if (JS('bool', 'typeof # != "function"', victim)) return const [];
  if (JS('bool', '# in #', r'$metadataIndex', victim)) {
    return JSArray.markFixedList(
        JS('JSExtendableArray',
           r'#.$reflectionInfo.splice(#.$metadataIndex)', victim, victim))
        .map((int i) => getMetadata(i)).toList();
  }
  String source = JS('String', 'Function.prototype.toString.call(#)', victim);
  int index = source.lastIndexOf(new RegExp('"[0-9,]*";?[ \n\r]*}'));
  if (index == -1) return const [];
  index++;
  int endQuote = source.indexOf('"', index);
  return source.substring(index, endQuote).split(',').map(int.parse).map(
      (int i) => getMetadata(i)).toList();
}

List<JsVariableMirror> parseCompactFieldSpecification(
    JsDeclarationMirror owner,
    fieldSpecification,
    bool isStatic,
    List<Mirror> result) {
  List fieldsMetadata = null;
  List<String> fields;
  if (fieldSpecification is List) {
    fields = splitFields(fieldSpecification[0], ',');
    fieldsMetadata = fieldSpecification.sublist(1);
  } else if (fieldSpecification is String) {
    fields = splitFields(fieldSpecification, ',');
  } else {
    fields = [];
  }
  int fieldNumber = 0;
  for (String field in fields) {
    var metadata;
    if (fieldsMetadata != null) {
      metadata = fieldsMetadata[fieldNumber++];
    }
    var mirror = new JsVariableMirror.from(field, metadata, owner, isStatic);
    if (mirror != null) {
      result.add(mirror);
    }
  }
}

/// Similar to [String.split], but returns an empty list if [string] is empty.
List<String> splitFields(String string, Pattern pattern) {
  if (string.isEmpty) return <String>[];
  return string.split(pattern);
}

bool isOperatorName(String name) {
  switch (name) {
  case '==':
  case '[]':
  case '*':
  case '/':
  case '%':
  case '~/':
  case '+':
  case '<<':
  case '>>':
  case '>=':
  case '>':
  case '<=':
  case '<':
  case '&':
  case '^':
  case '|':
  case '-':
  case 'unary-':
  case '[]=':
  case '~':
    return true;
  default:
    return false;
  }
}

/// Returns true if the key represent ancillary reflection data, that is, not a
/// method.
bool isReflectiveDataInPrototype(String key) {
  if (key == '' || key == METHODS_WITH_OPTIONAL_ARGUMENTS) return true;
  String firstChar = key[0];
  return firstChar == '*' || firstChar == '+';
}

class NoSuchStaticMethodError extends Error implements NoSuchMethodError {
  static const int MISSING_CONSTRUCTOR = 0;
  final ClassMirror _cls;
  final Symbol _name;
  final List _positionalArguments;
  final Map<Symbol, dynamic> _namedArguments;
  final int _kind;

  NoSuchStaticMethodError.missingConstructor(
      this._cls,
      this._name,
      this._positionalArguments,
      this._namedArguments)
      : _kind = MISSING_CONSTRUCTOR;

  String toString() {
    switch(_kind) {
    case MISSING_CONSTRUCTOR:
      return
          "NoSuchMethodError: No constructor named '${n(_name)}' in class"
          " '${n(_cls.qualifiedName)}'.";
    default:
      return 'NoSuchMethodError';
    }
  }
}

// Copied from package "unmodifiable_collection".
// TODO(14314): Move to dart:collection.
class UnmodifiableMapView<K, V> implements Map<K, V> {
  Map<K, V> _source;
  UnmodifiableMapView(Map<K, V> source) : _source = source;

  static void _throw() {
    throw new UnsupportedError("Cannot modify an unmodifiable Map");
  }

  int get length => _source.length;

  bool get isEmpty => _source.isEmpty;

  bool get isNotEmpty => _source.isNotEmpty;

  V operator [](K key) => _source[key];

  bool containsKey(K key) => _source.containsKey(key);

  bool containsValue(V value) => _source.containsValue(value);

  void forEach(void f(K key, V value)) => _source.forEach(f);

  Iterable<K> get keys => _source.keys;

  Iterable<V> get values => _source.values;


  void operator []=(K key, V value) => _throw();

  V putIfAbsent(K key, V ifAbsent()) { _throw(); }

  void addAll(Map<K, V> other) => _throw();

  V remove(K key) { _throw(); }

  void clear() => _throw();
}
