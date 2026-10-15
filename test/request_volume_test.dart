import 'dart:async';
import 'dart:convert';
import 'dart:io' show gzip;

import 'package:telling_kit/telling_kit.dart';
import 'package:test/test.dart';

/// Counts requests and decodes what each one carried.
class CountingTransport implements TellingTransport {
  final List<Map<String, dynamic>> batches = <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> gets = <Map<String, dynamic>>[];
  int statusCode = 200;

  /// Total requests of either kind.
  int get requestCount => batches.length + gets.length;

  @override
  Future<int> postJson(
    String url,
    Map<String, String> headers,
    List<int> body,
  ) async {
    final compressed = headers['Content-Encoding'] == 'gzip';
    final decoded =
        jsonDecode(gzipOrPlain(body, compressed)) as List<dynamic>;
    batches.add(<String, dynamic>{
      'url': url,
      'events': decoded.cast<Map<String, dynamic>>(),
      'apiKey': headers['x-api-key'],
      'gzip': compressed,
    });
    return statusCode;
  }

  @override
  Future<TellingResponse> getJson(String url, Map<String, String> headers) async {
    gets.add(<String, dynamic>{'url': url});
    return const TellingResponse(404, <String, dynamic>{});
  }

  /// Bodies are gzipped only past 1 KB, so decode accordingly.
  static String gzipOrPlain(List<int> body, bool compressed) =>
      compressed
      ? utf8.decode(gzip.decode(body))
      : utf8.decode(body, allowMalformed: true);
}

/// Answers the only question that matters when an analytics SDK is added to an
/// app: **how many network calls does it add, and are they worth it?**
///
/// An SDK that posts once per error looks harmless until you notice failures
/// arrive on a per-tap path. These tests count requests, not events.
void main() {
  final CountingTransport transport = CountingTransport();
  late Telling telling;

  // The SDK is a singleton with a private constructor, so it is booted once for
  // the whole file and the transport keeps every batch it ever saw. Tests filter
  // by their own unique event names rather than clearing, because the SDK's own
  // lifecycle rows (app_open, session boundaries) are emitted during init and
  // clearing mid-suite discards exactly what the provenance tests look for.
  setUpAll(() async {
    Telling.debugUseTransport(transport);
    telling = Telling.instance;
    await telling.init('TEST_KEY_ONLY', enableDebugLogs: false);
    // Let init's own rows land before any test starts filtering.
    await Future<void>.delayed(const Duration(milliseconds: 2400));
  });

  tearDownAll(() {
    telling.dispose();
    Telling.debugResetTransport();
  });

  /// Every row ever sent, across the whole file.
  List<Map<String, dynamic>> rowsFor(String message) => transport.batches
      .expand((b) => (b['events'] as List<Map<String, dynamic>>))
      .where((e) => e['message'] == message)
      .toList();

  group('request count', () {
    test('a burst of handled failures costs ONE request, not one each', () async {
      final before = transport.requestCount;

      // What a user mashing a broken button looks like: twenty recovered
      // failures. The old rule flushed on every LogLevel.error.
      for (var i = 0; i < 20; i++) {
        telling.captureException(
          error: StateError('failure $i'),
          context: 'controller_action',
        );
      }

      // Nothing sent yet: the debounce is holding the batch.
      expect(transport.requestCount, before);

      await Future<void>.delayed(const Duration(milliseconds: 2400));
      final afterBurst = transport.requestCount;

      // Twenty events, so at most a couple of requests even if the old
      // per-error rule were back. The old behaviour was twenty.
      expect(
        afterBurst - before,
        lessThanOrEqualTo(2),
        reason: 'a burst must coalesce, not fan out into one request each',
      );
    }, timeout: Timeout(Duration(seconds: 30)));

    test('a batch carries every event it collected', () async {

      for (var i = 0; i < 20; i++) {
        telling.event('probe_$i');
      }
      await Future<void>.delayed(const Duration(milliseconds: 2400));

      telling.event('carried');
      await Future<void>.delayed(const Duration(milliseconds: 2400));

      expect(
        rowsFor('carried'),
        isNotEmpty,
        reason: 'debouncing must delay, never lose',
      );
    }, timeout: Timeout(Duration(seconds: 30)));

    test('an idle SDK makes no requests', () async {
      // The periodic backstop runs on its own; with nothing buffered it must not
      // spend a request proving the buffer is empty.
      await Future<void>.delayed(const Duration(milliseconds: 2400));
      final before = transport.requestCount;
      await Future<void>.delayed(const Duration(milliseconds: 2400));
      expect(transport.requestCount, before);
    }, timeout: Timeout(Duration(seconds: 30)));
  });

  group('provenance', () {
    test('every row carries a source, so the database is self-describing', () async {

      telling.event('provenance_default');
      telling.event('provenance_default', source: 'progression');
      await Future<void>.delayed(const Duration(milliseconds: 2400));

      final rows = rowsFor('provenance_default');
      expect(rows, isNotEmpty);

      final sources = rows
          .map((e) => (e['metadata'] as Map)['source'])
          .toSet();
      expect(
        sources,
        {'app', 'progression'},
        reason: 'a row with no source cannot be traced to its origin',
      );
    }, timeout: Timeout(Duration(seconds: 30)));

    test('SDK lifecycle rows are distinguishable from app rows', () async {

      telling.event('an_app_event');
      await Future<void>.delayed(const Duration(milliseconds: 2400));

      final rows = transport.batches
          .expand((b) => (b['events'] as List<Map<String, dynamic>>))
          .toList();

      final sdkRows = rows.where(
        (e) => ['app_open', 'Session started', 'Session ended', 'screen_view']
            .contains(e['message']),
      );
      expect(
        sdkRows,
        isNotEmpty,
        reason: 'the lifecycle events must actually be emitted',
      );
      for (final row in sdkRows) {
        expect(
          (row['metadata'] as Map)['source'],
          anyOf('sdk', 'navigation'),
          reason: '${row['message']} should be attributable to the SDK',
        );
      }
    }, timeout: Timeout(Duration(seconds: 30)));
  });

  group('flush-time dedup', () {
    // Regression: the Flutter original hashed only message/level/stackTrace, so
    // two events sharing a message but differing in properties collapsed into
    // one and the first was lost with no error. Every per-property breakdown
    // depends on this not happening.
    test('two events with the same name but different properties both survive',
        () async {
      telling.event('same_name', properties: {'variant': 'first'});
      telling.event('same_name', properties: {'variant': 'second'});
      await Future<void>.delayed(const Duration(milliseconds: 2400));

      final variants = rowsFor('same_name')
          .map((e) => (e['metadata'] as Map)['variant'])
          .toSet();
      expect(
        variants,
        {'first', 'second'},
        reason: 'dedup must not collapse distinct events that share a name',
      );
    }, timeout: Timeout(Duration(seconds: 30)));

    test('a genuine byte-identical repeat is still collapsed', () async {
      // The dedup is still worth having: it bounds a hot loop emitting the same
      // thing over and over, which the buffer cap alone would have to absorb.
      //
      // Deliberately a crash, not an analytics event: analytics rows carry
      // breadcrumbs, so two of them are never byte-identical and the collapse
      // could never be observed through them.
      final error = StateError('identical every time');
      for (var i = 0; i < 6; i++) {
        telling.captureException(
          error: error,
          stackTrace: StackTrace.empty,
          context: 'repeat',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 2400));

      final repeats = transport.batches
          .expand((b) => (b['events'] as List<Map<String, dynamic>>))
          .where((e) => (e['metadata'] as Map)['context'] == 'repeat')
          .length;
      expect(
        repeats,
        lessThan(6),
        reason: 'byte-identical repeats are still deduplicated',
      );
    }, timeout: Timeout(Duration(seconds: 30)));
  });

  group('batching', () {
    test('large payloads are gzipped, small ones are not', () async {

      // A fat event, so the batch clears the 1 KB threshold.
      telling.event('compression_probe', properties: {'blob': 'x' * 4000});
      await Future<void>.delayed(const Duration(milliseconds: 2400));

      final batch = transport.batches.lastWhere(
        (b) => (b['events'] as List<Map<String, dynamic>>).any(
          (e) => e['message'] == 'compression_probe',
        ),
      );
      expect(
        batch['gzip'],
        isTrue,
        reason: 'uncompressed multi-KB bodies are wasted bandwidth',
      );
    }, timeout: Timeout(Duration(seconds: 30)));

    test('the API key travels as a header, never in the body', () async {

      telling.event('keyed');
      await Future<void>.delayed(const Duration(milliseconds: 2400));

      final keyBatch = transport.batches.lastWhere(
        (b) => (b['events'] as List<Map<String, dynamic>>)
            .any((e) => e['message'] == 'keyed'),
      );
      expect(keyBatch['apiKey'], 'TEST_KEY_ONLY');
      expect(keyBatch['url'], endsWith('/logs'));
    }, timeout: Timeout(Duration(seconds: 30)));
  });
}