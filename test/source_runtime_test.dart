import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/sources/package.dart';
import 'package:asterlink/data/sources/runtime.dart';
import 'package:asterlink/data/sources/host.dart';

Json sourceFixture(String code, {Map<String, String> modules = const {}}) => {
  'schema': 1,
  'id': 'example_source',
  'name': '示例来源',
  'entry': 'main.js',
  'requires': {'source': 1, 'javascript': 1, 'http': 1, 'html': 1, 'crypto': 1},
  'match': [
    {'host': 'example.com', 'pathPrefix': '/share/'},
  ],
  'permissions': {
    'hosts': ['example.com'],
    'downloadHosts': ['files.example.com'],
    'methods': ['GET', 'POST'],
    'headers': ['X-Sign', 'Content-Type'],
  },
  'operations': {'resolve': 'resolve', 'download': 'download'},
  'modules': {'main.js': code, ...modules},
};
void main() {
  final library = Platform.environment['ASTERLINK_JS_LIBRARY'];
  final native = library != null && File(library).existsSync();
  test(
    'Dynamic sources use independent identities and declare capability requirements',
    () {
      final source = SourcePackage.fromJson(
        sourceFixture('export function resolve(){}'),
      );
      expect(source.id, 'example_source');
      expect(source.compatible, true);
      expect(source.matches(Uri.parse('https://example.com/share/new')), true);
      expect(
        source.matches(Uri.parse('https://example.com.attacker.com/share/new')),
        false,
      );
      final future = sourceFixture('export function resolve(){}');
      future['requires']['future_feature'] = 1;
      expect(SourcePackage.fromJson(future).compatible, false);
      expect(
        () => source.checkedUrl('https://elsewhere.com'),
        throwsA(isA<SourceError>()),
      );
      expect(
        () => source.checkedHeaders({'Cookie': 'account=secret'}),
        throwsA(isA<SourceError>()),
      );
    },
  );
  test('Native modules support imports and modern JavaScript', () async {
    final source = SourcePackage.fromJson(
      sourceFixture(
        "import {sum} from './math.js'; export async function resolve(input){ return {sum:sum(input.values), big:(2n ** 64n).toString()}; }",
        modules: {
          'math.js': 'export const sum = xs => xs.reduce((a,b)=>a+b,0);',
        },
      ),
    );
    final result = await SourceRuntime(libraryPath: library).run(
      source,
      'resolve',
      {
        'values': [1, 2, 3],
      },
      SourceHost(source).call,
    );
    expect(result, {'sum': 6, 'big': '18446744073709551616'});
  }, skip: !native);
  test(
    'JSON HTML and script signatures execute through bounded host calls',
    () async {
      final source = SourcePackage.fromJson(
        sourceFixture('''
export async function resolve(input, api) {
  const sign = await api.crypto('hash', ['sha256', 'abc']);
  const response = await api.request({url:'https://example.com/share/demo', headers:{'X-Sign':sign}});
  const page = await api.html(response.text, {files:{selector:'a.file', attributes:['href']}});
  return {items:page.files.map((row,i)=>({id:String(i),name:row.text,url:row.href})), sign};
}
'''),
      );
      var count = 0;
      final host = SourceHost(
        source,
        fetch: (s, args) async {
          count++;
          expect(
            args.obj('headers').str('X-Sign'),
            'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
          );
          return {
            'status': 200,
            'text': '<a class="file" href="/a.zip">示例.zip</a>',
          };
        },
      );
      final result = await SourceRuntime(
        libraryPath: library,
      ).run(source, 'resolve', {}, host.call);
      expect(result.list('items').single.str('name'), '示例.zip');
      expect(count, 1);
    },
    skip: !native,
  );
  for (final entry in {
    'infinite loop': 'export function resolve(){ while(true){} }',
    'promise loop':
        'export async function resolve(){while(true){await Promise.resolve();}}',
    'memory exhaustion':
        'export function resolve(){const a=[];while(true){a.push(new Uint8Array(1024*1024));}}',
    'recursion':
        'export function resolve(){function recur(){return 1+recur();}return recur();}',
    'blocking atomics':
        'export function resolve(){Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0);}',
  }.entries) {
    test(
      'Native runtime terminates ${entry.key} and remains reusable',
      () async {
        final source = SourcePackage.fromJson(sourceFixture(entry.value));
        final clock = Stopwatch()..start();
        await expectLater(
          SourceRuntime(
            libraryPath: library,
          ).run(source, 'resolve', {}, SourceHost(source).call),
          throwsA(isA<SourceError>()),
        );
        expect(clock.elapsedMilliseconds, lessThan(5000));
        final good = SourcePackage.fromJson(
          sourceFixture('export function resolve(){return {ok:true};}'),
        );
        expect(
          (await SourceRuntime(
            libraryPath: library,
          ).run(good, 'resolve', {}, SourceHost(good).call))['ok'],
          true,
        );
      },
      skip: !native,
    );
  }
  test(
    'Cancellation while an asynchronous source waits releases its isolate',
    () async {
      final source = SourcePackage.fromJson(
        sourceFixture(
          'export async function resolve(input,api){await api.sleep(10000);return {ok:true};}',
        ),
      );
      final scope = RequestScope();
      final future = scope.run(
        () => SourceRuntime(
          libraryPath: library,
        ).run(source, 'resolve', {}, SourceHost(source).call),
      );
      final check = expectLater(future, throwsA(isA<AppException>()));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      scope.cancel();
      await check;
    },
    skip: !native,
  );
  test('Package imports cannot load OS, network or absent modules', () async {
    for (final name in [
      'std',
      'os',
      'https://example.com/remote.js',
      '../outside.js',
    ]) {
      final source = SourcePackage.fromJson(
        sourceFixture(
          "import '$name'; export function resolve(){return {ok:true};}",
        ),
      );
      await expectLater(
        SourceRuntime(
          libraryPath: library,
        ).run(source, 'resolve', {}, SourceHost(source).call),
        throwsA(isA<SourceError>()),
      );
    }
  }, skip: !native);
  test('Top-level await completes before exported functions are read', () async {
    final source = SourcePackage.fromJson(
      sourceFixture(
        'const value=await Promise.resolve(42); export function resolve(){return {value,process:typeof process,fetch:typeof fetch,require:typeof require};}',
      ),
    );
    expect(
      await SourceRuntime(
        libraryPath: library,
      ).run(source, 'resolve', {}, SourceHost(source).call),
      {
        'value': 42,
        'process': 'undefined',
        'fetch': 'undefined',
        'require': 'undefined',
      },
    );
  }, skip: !native);
}
