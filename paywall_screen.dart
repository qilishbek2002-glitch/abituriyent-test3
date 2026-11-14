import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../config.dart';
import '../l10n.dart';
import '../theme.dart';
import '../ui.dart';

/// Test tuzish/yechishga ruxsat bor-yo'qligini tekshiradi.
/// Ruxsat bo'lmasa to'lov oynasini ochadi va false qaytaradi.
bool ensureAccess(BuildContext context) {
  if (app.canGenerate) return true;
  Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => const PaywallScreen()),
  );
  return false;
}

Future<void> openBot(BuildContext context) async {
  var ok = false;
  try {
    ok = await launchUrl(Uri.parse('https://t.me/$kBotUsername'),
        mode: LaunchMode.externalApplication);
  } catch (_) {
    ok = false;
  }
  if (!ok && context.mounted) showSnack(context, tr('cannot_open_link'));
}

/// Obuna holati kartasi: necha kunlik tarif va qancha kun qolgani.
class SubscriptionCard extends StatelessWidget {
  final VoidCallback? onTap;
  const SubscriptionCard({super.key, this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = brandGradient(context);
    final sub = app.subscribed;
    final children = <Widget>[];
    if (sub) {
      children.add(Row(
        children: [
          const Icon(Icons.verified, color: Colors.white),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              app.planDays > 0
                  ? tr('plan_name', {'d': '${app.planDays}'})
                  : tr('subscription'),
              style: const TextStyle(
                  color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ));
      children.add(const SizedBox(height: 10));
      children.add(Text(
        app.daysLeft == 0
            ? tr('sub_today')
            : tr('sub_left_line', {'d': '${app.daysLeft}'}),
        style: const TextStyle(
            color: Colors.white, fontSize: 26, fontWeight: FontWeight.w800),
      ));
      if (app.planDays > 0) {
        children.add(const SizedBox(height: 10));
        children.add(ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: app.planFraction,
            minHeight: 8,
            color: Colors.white,
            backgroundColor: Colors.white24,
          ),
        ));
      }
      children.add(const SizedBox(height: 8));
      children.add(Text(
        tr('sub_until_line', {'s': app.expiryLabel}),
        style: const TextStyle(color: Colors.white70),
      ));
    } else {
      children.add(Row(
        children: [
          const Icon(Icons.lock_open, color: Colors.white),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              app.expiryYmd.isNotEmpty ? tr('sub_expired') : tr('sub_none'),
              style: const TextStyle(
                  color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ));
      children.add(const SizedBox(height: 8));
      children.add(Text(
        app.trialLeft > 0
            ? tr('trial_left', {'n': '${app.trialLeft}', 'q': '$kFreeQuestions'})
            : tr('trial_over'),
        style: const TextStyle(color: Colors.white, fontSize: 15),
      ));
    }
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
            begin: Alignment.topLeft, end: Alignment.bottomRight, colors: colors),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children,
            ),
          ),
        ),
      ),
    );
  }
}

class PaywallScreen extends StatefulWidget {
  const PaywallScreen({super.key});

  @override
  State<PaywallScreen> createState() => _PaywallScreenState();
}

class _PaywallScreenState extends State<PaywallScreen> {
  final TextEditingController _ctrl = TextEditingController();
  String? _msg;
  bool _busy = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) showSnack(context, tr('copied'));
  }

  Future<void> _activate() async {
    if (_ctrl.text.trim().isEmpty) return;
    setState(() {
      _busy = true;
      _msg = null;
    });
    final r = await app.activate(_ctrl.text);
    if (!mounted) return;
    setState(() => _busy = false);
    switch (r) {
      case ActivateResult.ok:
        showSnack(context, tr('code_ok', {'s': app.lastActivatedExpiry}));
        Navigator.of(context).pop();
        break;
      case ActivateResult.bad:
        setState(() => _msg = tr('code_bad'));
        break;
      case ActivateResult.wrongDevice:
        setState(() => _msg = tr('code_other_device'));
        break;
      case ActivateResult.expired:
        setState(() => _msg = tr('code_expired'));
        break;
    }
  }

  int _savePercent(Plan p) {
    final base = kPlans.first.price / kPlans.first.days;
    final cur = p.price / p.days;
    final v = ((1 - cur / base) * 100).round();
    return v;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        return Scaffold(
          appBar: AppBar(title: Text(tr('subscription'))),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const SubscriptionCard(),
                const SizedBox(height: 16),
                Text(tr('plans'),
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                for (final p in kPlans) _planTile(p, scheme),
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(tr('bot_steps'),
                        style: const TextStyle(fontSize: 15, height: 1.45)),
                  ),
                ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(52)),
                  onPressed: () => openBot(context),
                  icon: const Icon(Icons.send),
                  label: Text(tr('open_bot', {'b': kBotUsername})),
                ),
                const SizedBox(height: 12),
                Card(
                  child: ListTile(
                    title: Text(app.deviceId,
                        style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 2)),
                    subtitle: Text(tr('device_id')),
                    trailing: IconButton(
                      tooltip: tr('copy'),
                      icon: const Icon(Icons.copy),
                      onPressed: () => _copy(app.deviceId),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _ctrl,
                  textCapitalization: TextCapitalization.characters,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: tr('enter_code'),
                    border: const OutlineInputBorder(),
                    errorText: _msg,
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.tonal(
                  style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(50)),
                  onPressed: _busy ? null : _activate,
                  child: _busy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(tr('activate')),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _planTile(Plan p, ColorScheme scheme) {
    final save = _savePercent(p);
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: scheme.primaryContainer,
          child: Text('${p.days}',
              style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                  color: scheme.onPrimaryContainer)),
        ),
        title: Text(tr('plan_name', {'d': '${p.days}'}),
            style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text(tr('price_som', {'p': fmtMoney(p.price)})),
        trailing: save > 0
            ? Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.green.withAlpha(40),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text('-$save%',
                    style: const TextStyle(
                        color: Colors.green, fontWeight: FontWeight.bold)),
              )
            : null,
      ),
    );
  }
}
