import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
            seedColor: const Color(0xFF00D4AA), brightness: Brightness.dark),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

const List<String> kFileHosts = [
  'gofile.io', 'mediafire.com', 'drive.google.com', 'mega.nz', 'mega.co.nz',
  'dropbox.com', 'box.com', 'onedrive.live.com', '1drv.ms', 'zippyshare.com',
  'anonfiles.com', 'bayfiles.com', 'rapidgator.net', 'uploaded.net',
  'nitroflare.com', 'turbobit.net', 'filefactory.com', 'sendspace.com',
  'wetransfer.com', 'pixeldrain.com', 'workupload.com', 'krakenfiles.com',
  'github.com', 'gitlab.com',
];

const List<String> kLockerHosts = [
  'sub4unlock.com', 'sub4unlock.co', 'sfl.gl', 'adf.ly', 'ouo.io', 'ouo.press',
  'linkvertise.com', 'link-to.net', 'linkunlock.in', 'shorte.st', 'bc.vc',
  'adfoc.us', 'oke.io', 'clk.sh', 'za.gl', 'gtlinks.me', 'gplinks.co',
  'shrinkearn.com', 'earn4files.com', 'upshrink.com',
];

class UnlockResult {
  final String input;
  final String finalUrl;
  final int status;
  final List<String> chain;
  final List<String> candidates;
  final List<String> originalLinks;
  final String title;
  UnlockResult({
    required this.input,
    required this.finalUrl,
    required this.status,
    required this.chain,
    required this.candidates,
    required this.originalLinks,
    required this.title,
  });
}

class Unlocker {
  static final _urlRe = RegExp(r"https?://[A-Za-z0-9._~:/?#@!$&'()*+,;=%-]+", caseSensitive: false);
  static final _metaRe = RegExp(
      r'<meta[^>]*content=[^>]*url=([^\s\x22\x27>]+)',
      caseSensitive: false);
  static final _jsRe = RegExp(
      r'location(?:\.href)?\s*=\s*[\x22\x27]([^\x22\x27\s]+)[\x22\x27]',
      caseSensitive: false);
  static final _openRe = RegExp(
      r'window\.open\(\s*[\x22\x27]([^\x22\x27\s]+)[\x22\x27]',
      caseSensitive: false);
  static final _b64Re = RegExp(r'[A-Za-z0-9+/]{24,}={0,2}');
  static final _titleRe =
      RegExp(r'<title[^>]*>(.*?)</title>', caseSensitive: false, dotAll: true);
  static final _formRe = RegExp(r'<form\b[^>]*>(.*?)</form>',
      caseSensitive: false, dotAll: true);

  static bool isFileHost(String u) {
    try {
      final h = Uri.parse(u).host.toLowerCase();
      return kFileHosts.any((d) => h == d || h.endsWith('.' + d));
    } catch (_) {
      return false;
    }
  }

  static bool isLockerHost(String u) {
    try {
      final h = Uri.parse(u).host.toLowerCase();
      return kLockerHosts.any((d) => h == d || h.endsWith('.' + d));
    } catch (_) {
      return false;
    }
  }

  static String _norm(String u) {
    var s = u.trim();
    s = s.replaceAll(r'\/', '/');
    s = s.replaceAll(r'\\', '');
    // html entities
    s = s.replaceAll('&amp;', '&');
    return s;
  }

  static String _clean(String u) => _norm(u).replaceAll(RegExp(r'[).,;\x22\x27]+'), '');

  static Map<String, String> _parseForm(String formHtml, String pageUrl) {
    final res = <String, String>{};
    final actionMatch = RegExp(r'action\s*=\s*[\x22\x27]([^"\x27]+)[\x22\x27]',
            caseSensitive: false)
        .firstMatch(formHtml);
    // inputs
    for (final m in RegExp(r'<input\b[^>]*>', caseSensitive: false).allMatches(formHtml)) {
      final tag = m.group(0)!;
      final name = RegExp(r'name\s*=\s*[\x22\x27]([^"\x27]+)[\x22\x27]',
              caseSensitive: false)
          .firstMatch(tag)
          ?.group(1);
      final value = RegExp(r'value\s*=\s*[\x22\x27]([^"\x27]*)[\x22\x27]',
              caseSensitive: false)
          .firstMatch(tag)
          ?.group(1);
      if (name != null) res[name] = value ?? '';
    }
    // method
    final methodMatch = RegExp(r'method\s*=\s*[\x22\x27]([^"\x27]+)[\x22\x27]',
            caseSensitive: false)
        .firstMatch(formHtml);
    res['__method__'] = (methodMatch?.group(1) ?? 'GET').toUpperCase();
    if (actionMatch != null) {
      res['__action__'] = Uri.parse(pageUrl).resolve(actionMatch.group(1)!).toString();
    }
    return res;
  }

  // Resolve a single URL: follow redirects, submit GET/POST forms, extract candidates.
  static Future<Map<String, dynamic>> _resolveOnce(String url) async {
    final client = http.Client();
    final chain = <String>[];
    String current = url;
    http.Response? last;
    int hops = 0;
    try {
      while (hops < 15) {
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
        // Form auto-submit
        final body = resp.body;
        bool submitted = false;
        for (final fm in _formRe.allMatches(body)) {
          final formHtml = fm.group(0)!;
          final parsed = _parseForm(formHtml, current);
          final action = parsed.remove('__action__');
          final method = parsed.remove('__method__') ?? 'GET';
          if (action == null) continue;
          if (method == 'GET') {
            final uri = Uri.parse(action).replace(queryParameters: {
              ...Uri.parse(action).queryParameters,
              ...parsed,
            });
            current = uri.toString();
            submitted = true;
            break;
          } else {
            // POST
            final postResp = await client.post(Uri.parse(action),
                body: parsed,
                headers: {
                  'User-Agent':
                      'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36',
                });
            chain.add(action);
            last = postResp;
            final ploc = postResp.headers['location'];
            if (ploc != null) {
              current = Uri.parse(action).resolve(ploc).toString();
              submitted = true;
              break;
            }
            // try extract from body
            current = action;
            submitted = true;
            break;
          }
        }
        if (submitted) {
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
      final u = _clean(m.group(0)!);
      if (u.startsWith('http')) cands.add(u);
    }
    for (final m in _metaRe.allMatches(body)) {
      try {
        cands.add(Uri.parse(resolvedFinal).resolve(_norm(m.group(1)!)).toString());
      } catch (_) {}
    }
    for (final m in _jsRe.allMatches(body)) {
      try {
        cands.add(Uri.parse(resolvedFinal).resolve(_norm(m.group(1)!)).toString());
      } catch (_) {}
    }
    for (final m in _openRe.allMatches(body)) {
      try {
        cands.add(Uri.parse(resolvedFinal).resolve(_norm(m.group(1)!)).toString());
      } catch (_) {}
    }
    for (final m in _b64Re.allMatches(body)) {
      try {
        final dec = utf8.decode(base64.decode(m.group(0)!));
        if (dec.startsWith('http')) cands.add(_clean(dec));
      } catch (_) {}
    }
    // JSON-escaped URLs already handled by _norm in _clean? ensure
    final jsonUrlRe = RegExp(r"https?:\\?/\\?/[A-Za-z0-9._~:/?#@!$&'()*+,;=%-\\]+", caseSensitive: false);
    for (final m in jsonUrlRe.allMatches(body)) {
      final u = _clean(m.group(0)!);
      if (u.startsWith('http')) cands.add(u);
    }

    return {
      'finalUrl': resolvedFinal,
      'status': status,
      'chain': chain,
      'candidates': cands,
      'body': body,
    };
  }

  static Future<UnlockResult> unlock(String raw) async {
    var url = raw.trim();
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url';
    }
    final allChain = <String>[];
    final allCands = <String>{};
    String current = url;
    String finalUrl = url;
    int status = 0;
    String body = '';
    final visited = <String>{};

    // Recursively resolve lockers up to 6 hops
    for (int i = 0; i < 6; i++) {
      if (visited.contains(current)) break;
      visited.add(current);
      final r = await _resolveOnce(current);
      finalUrl = r['finalUrl'] as String;
      status = r['status'] as int;
      body = r['body'] as String;
      allChain.addAll(r['chain'] as List<String>);
      allCands.addAll(r['candidates'] as Set<String>);
      // decide next
      String? next;
      // if final is locker, look for candidate that is file host or non-locker
      if (isLockerHost(finalUrl)) {
        // prefer file host candidate
        final fileCands = (r['candidates'] as Set<String>).where(isFileHost).toList();
        if (fileCands.isNotEmpty) {
          next = fileCands.first;
        } else {
          // pick first candidate that is not a locker and not ad
          for (final c in (r['candidates'] as Set<String>)) {
            if (!isLockerHost(c)) {
              next = c;
              break;
            }
          }
        }
      } else {
        // final not locker; but maybe a candidate is a deeper locker? stop
        next = null;
      }
      if (next == null || next == current || visited.contains(next)) break;
      current = next;
    }

    const adDomains = {
      'doubleclick.net', 'googlesyndication.com', 'googleadservices.com',
      'facebook.com', 'fbcdn.net', 'twitter.com', 'x.com', 't.co',
      'analytics.google.com', 'googletagmanager.com', 'adservice.google.com',
      'popads.net', 'popcash.net', 'propellerads.com', 'adsterra.com',
      'mgid.com', 'revcontent.com', 'taboola.com', 'outbrain.com',
    };
    bool isAd(String u) {
      try {
        final h = Uri.parse(u).host.toLowerCase();
        return adDomains.any((d) => h == d || h.endsWith('.' + d));
      } catch (_) {
        return false;
      }
    }

    final filtered = <String>[];
    final seen = <String>{};
    for (final c in allCands) {
      if (isAd(c)) continue;
      if (seen.add(c)) filtered.add(c);
    }
    filtered.sort((a, b) {
      final fa = isFileHost(a) ? 0 : 1;
      final fb = isFileHost(b) ? 0 : 1;
      if (fa != fb) return fa.compareTo(fb);
      final la = isLockerHost(a) ? 1 : 0;
      final lb = isLockerHost(b) ? 1 : 0;
      if (la != lb) return la.compareTo(lb);
      return a.length.compareTo(b.length);
    });

    final originalLinks = filtered.where(isFileHost).toList();
    // if no file host, use final url if not locker
    if (originalLinks.isEmpty && !isLockerHost(finalUrl)) {
      originalLinks.add(finalUrl);
    }

    final titleMatch = _titleRe.firstMatch(body);
    final title = titleMatch != null
        ? _stripTags(titleMatch.group(1)!)
        : '';

    return UnlockResult(
      input: url,
      finalUrl: finalUrl,
      status: status,
      chain: allChain,
      candidates: filtered.take(100).toList(),
      originalLinks: originalLinks,
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

  Future<void> _copy(String u) async {
    await Clipboard.setData(ClipboardData(text: u));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('copied'), duration: Duration(seconds: 1)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Link Unlocker'),
        centerTitle: false,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('Paste locker URL',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text('sfgl, sub4unlock, adf.ly, ouo, dll. Auto-resolve nested lockers.',
                        style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _ctrl,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        hintText: 'https://...',
                        prefixIcon: Icon(Icons.link),
                      ),
                      onSubmitted: (_) => _go(),
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: _loading ? null : _go,
                      icon: _loading
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.lock_open),
                      label: Text(_loading ? 'resolving...' : 'Unlock'),
                    ),
                  ],
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Card(
                color: cs.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(_error!, style: TextStyle(color: cs.onErrorContainer)),
                ),
              ),
            ],
            if (_result != null) ...[
              const SizedBox(height: 12),
              if (_result!.originalLinks.isNotEmpty)
                Card(
                  color: cs.primaryContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Icon(Icons.verified, color: cs.onPrimaryContainer),
                          const SizedBox(width: 8),
                          Text('Original link terdeteksi',
                              style: TextStyle(
                                  color: cs.onPrimaryContainer,
                                  fontWeight: FontWeight.bold)),
                        ]),
                        const SizedBox(height: 8),
                        ..._result!.originalLinks.map((l) => Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Row(children: [
                                Expanded(
                                  child: SelectableText(l,
                                      style: TextStyle(color: cs.onPrimaryContainer)),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.copy),
                                  onPressed: () => _copy(l),
                                  color: cs.onPrimaryContainer,
                                ),
                                IconButton(
                                  icon: const Icon(Icons.open_in_new),
                                  onPressed: () => _open(l),
                                  color: cs.onPrimaryContainer,
                                ),
                              ]),
                            )),
                      ],
                    ),
                  ),
                ),
              if (_result!.title.isNotEmpty)
                _Block(title: 'title', child: Text(_result!.title)),
              _Block(
                title: 'status',
                child: Text('${_result!.status} · final: ${_result!.finalUrl}'),
              ),
              _Block(
                title: 'redirect chain (${_result!.chain.length})',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: _result!.chain
                      .asMap()
                      .entries
                      .map((e) => Text('${e.key}: ${e.value}',
                          style: const TextStyle(fontSize: 12)))
                      .toList(),
                ),
              ),
              if (_result!.candidates.isNotEmpty)
                _Block(
                  title: 'candidate links (${_result!.candidates.length})',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: _result!.candidates
                        .map((l) => Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: Row(children: [
                                Expanded(
                                  child: OutlinedButton(
                                    onPressed: () => _open(l),
                                    child: Text(l,
                                        textAlign: TextAlign.left,
                                        style: const TextStyle(fontSize: 12)),
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.copy, size: 18),
                                  onPressed: () => _copy(l),
                                ),
                              ]),
                            ))
                        .toList(),
                  ),
                )
              else
                _Block(
                  title: 'candidate links',
                  child: const Text('none found - inspect redirect chain manually'),
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
