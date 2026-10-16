import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

void main() => runApp(const UnlockerApp());

class UnlockerApp extends StatelessWidget {
  const UnlockerApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Link Unlocker',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF58A6FF), brightness: Brightness.dark),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class UnlockResult {
  final String input;
  final String finalUrl;
  final int status;
  final List<String> chain;
  final List<String> candidates;
  final String title;
  UnlockResult({
    required this.input,
    required this.finalUrl,
    required this.status,
    required this.chain,
    required this.candidates,
    required this.title,
  });
}

class Unlocker {
  static final _urlRe = RegExp(r'https?://[^\s"''<>]+', caseSensitive: false);
  static final _metaRe = RegExp(
      r'<meta[^>]+http-equiv=["'']?refresh["'']?[^>]*content=["'']?[^"']*url=([^"''>\s]+)',
      caseSensitive: false);
  static final _jsRe = RegExp(
      r'(?:window\.|document\.|top\.|self\.)?location(?:\.href)?\s*=\s*["'']([^"'' ]+)["'']',
      caseSensitive: false);
  static final _openRe = RegExp(r'window\.open\(\s*["'']([^"'' ]+)["'']',
      caseSensitive: false);
  static final _titleRe =
      RegExp(r'<title[^>]*>(.*?)</title>', caseSensitive: false, dotAll: true);

  static Future<UnlockResult> unlock(String raw) async {
    var url = raw.trim();
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url';
    }
    final client = http.Client();
    final chain = <String>[];
    String current = url;
    http.Response? last;
    int hops = 0;
    try {
      while (hops < 10) {
        final req = http.Request('GET', Uri.parse(current))
          ..followRedirects = false
          ..headers['User-Agent'] =
              'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36'
          ..headers['Accept'] =
              'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8';
        final streamed = await client.send(req);
        final resp = await http.Response.fromStream(streamed);
        chain.add(current);
        last = resp;
        final loc = resp.headers['location'];
        if (loc != null &&
            (resp.statusCode == 301 ||
                resp.statusCode == 302 ||
                resp.statusCode == 303 ||
                resp.statusCode == 307 ||
                resp.statusCode == 308)) {
          current = Uri.parse(current).resolve(loc).toString();
          hops++;
          continue;
        }
        break;
      }
    } finally {
      client.close();
    }
    final resolvedFinal = chain.isNotEmpty ? chain.last : url;
    final body = last?.body ?? '';
    final status = last?.statusCode ?? 0;

    final cands = <String>{};
    for (final m in _urlRe.allMatches(body)) {
      var u = m.group(0)!.trim().replaceAll(RegExp(r'[).,;"'']+$'), '');
      if (u.startsWith('http')) cands.add(u);
    }
    for (final m in _metaRe.allMatches(body)) {
      try {
        cands.add(Uri.parse(resolvedFinal).resolve(m.group(1)!.trim()).toString());
      } catch (_) {}
    }
    for (final m in _jsRe.allMatches(body)) {
      try {
        cands.add(Uri.parse(resolvedFinal).resolve(m.group(1)!.trim()).toString());
      } catch (_) {}
    }
    for (final m in _openRe.allMatches(body)) {
      try {
        cands.add(Uri.parse(resolvedFinal).resolve(m.group(1)!.trim()).toString());
      } catch (_) {}
    }

    const adDomains = {
      'doubleclick.net','googlesyndication.com','googleadservices.com',
      'facebook.com','fbcdn.net','twitter.com','x.com','t.co',
      'analytics.google.com','googletagmanager.com','adservice.google.com',
      'popads.net','popcash.net','propellerads.com','adsterra.com',
      'mgid.com','revcontent.com','taboola.com','outbrain.com',
    };
    bool isAd(String u) {
      try {
        final h = Uri.parse(u).host.toLowerCase();
        return adDomains.any((d) => h == d || h.endsWith('.$d'));
      } catch (_) {
        return false;
      }
    }
    final inputHost = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    final filtered = <String>[];
    final seen = <String>{};
    for (final c in cands) {
      if (c == resolvedFinal) continue;
      if (chain.contains(c)) continue;
      if (isAd(c)) continue;
      if (seen.add(c)) filtered.add(c);
    }
    // rank: different host from input first, then shorter
    filtered.sort((a, b) {
      final ha = Uri.tryParse(a)?.host.toLowerCase() ?? '';
      final hb = Uri.tryParse(b)?.host.toLowerCase() ?? '';
      final da = (ha != inputHost && ha.isNotEmpty) ? 0 : 1;
      final db = (hb != inputHost && hb.isNotEmpty) ? 0 : 1;
      if (da != db) return da.compareTo(db);
      return a.length.compareTo(b.length);
    });

    final titleMatch = _titleRe.firstMatch(body);
    final title = titleMatch != null
        ? _stripTags(titleMatch.group(1)!)
        : '';

    return UnlockResult(
      input: url,
      finalUrl: resolvedFinal,
      status: status,
      chain: chain,
      candidates: filtered.take(60).toList(),
      title: title,
    );
  }

  static String _stripTags(String s) =>
      s.replaceAll(RegExp(r'<[^>]*>'), '').trim();
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _ctrl = TextEditingController();
  bool _loading = false;
  String? _error;
  UnlockResult? _result;

  Future<void> _go() async {
    final u = _ctrl.text.trim();
    if (u.isEmpty) {
      setState(() => _error = 'masukkan URL dulu');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _result = null;
    });
    try {
      final r = await Unlocker.unlock(u);
      setState(() => _result = r);
    } catch (e) {
      setState(() => _error = 'gagal: $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _open(String u) async {
    final uri = Uri.tryParse(u);
    if (uri == null) return;
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Link Unlocker')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Paste sfgl / sub4unlock / locker URL. App follows redirects & scrapes candidate final links.',
              style: TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _ctrl,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'https://...',
              ),
              onSubmitted: (_) => _go(),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _loading ? null : _go,
              child: Text(_loading ? 'fetching…' : 'Unlock'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: Colors.redAccent)),
            ],
            if (_result != null) ...[
              const SizedBox(height: 16),
              if (_result!.title.isNotEmpty)
                _Block(title: 'title', child: Text(_result!.title)),
              _Block(
                title: 'redirect chain (${_result!.chain.length})',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: _result!.chain
                      .asMap()
                      .entries
                      .map((e) => Text('${e.key}: ${e.value}',
                          style: const TextStyle(fontSize: 13)))
                      .toList(),
                ),
              ),
              _Block(
                title: 'status',
                child: Text('${_result!.status} · final: ${_result!.finalUrl}'),
              ),
              if (_result!.candidates.isNotEmpty)
                _Block(
                  title: 'candidate links (${_result!.candidates.length})',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: _result!.candidates
                        .map((l) => Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: OutlinedButton(
                                onPressed: () => _open(l),
                                child: Text(l,
                                    textAlign: TextAlign.left,
                                    style: const TextStyle(fontSize: 13)),
                              ),
                            ))
                        .toList(),
                  ),
                )
              else
                _Block(
                  title: 'candidate links',
                  child: const Text('none found — inspect redirect chain manually'),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Block extends StatelessWidget {
  final String title;
  final Widget child;
  const _Block({required this.title, required this.child});
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title.toUpperCase(),
              style: const TextStyle(
                  fontSize: 11, letterSpacing: 0.5, color: Colors.white54)),
          const SizedBox(height: 6),
          child,
        ],
      ),
    );
  }
}
