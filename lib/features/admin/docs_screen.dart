import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/theme_toggle_button.dart';

/// Admin-only architecture docs. Native Flutter (no WebView, no
/// markdown) so the page reads the same as the rest of the app —
/// Material 3, Inter, indigo+amber palette, compact cards, tight
/// rhythm. Diagrams are rendered as vertical stacks of flow-card
/// nodes with arrow icons between them (no chart package needed at
/// this complexity).
///
/// Tabs follow the natural read order of "what runs where", "who
/// talks to who", and "what data lives where":
///   - **Flow** — system overview + Gmail-to-notification sequence +
///     auth flavors + service-account matrix.
///   - **Services** — every GCP service still in use.
///   - **Endpoints & storage** — API routes + data-storage matrix +
///     features shipped.
class DocsScreen extends StatelessWidget {
  const DocsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Architecture'),
          actions: const [ThemeToggleButton()],
          bottom: const _CompactTopTabBar(
            tabs: [
              _TabSpec('Flow'),
              _TabSpec('Services'),
              _TabSpec('Endpoints'),
            ],
          ),
        ),
        body: const TabBarView(
          physics: BouncingScrollPhysics(),
          children: [
            _FlowTab(),
            _ServicesTab(),
            _EndpointsStorageTab(),
          ],
        ),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────
// Top tab bar — custom so it matches the rest of the app's typography
// (Inter, titleSmall) and stays compact (44 dp vs Material default 72).
// Same underline-indicator pattern as Material TabBar but with the
// app's spacing rhythm: tight horizontal padding, no overshoot
// padding on the trailing tab, thin divider under the bar.
// ────────────────────────────────────────────────────────────────────────

class _TabSpec {
  const _TabSpec(this.label);
  final String label;
}

class _CompactTopTabBar extends StatelessWidget implements PreferredSizeWidget {
  const _CompactTopTabBar({required this.tabs});
  final List<_TabSpec> tabs;

  @override
  Size get preferredSize => const Size.fromHeight(44);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final controller = DefaultTabController.of(context);
    // Listen to controller.animation (ticks every swipe frame) instead
    // of controller (notifies only on settle). Without this, the
    // active-tab highlight lags behind the swipe — the highlight only
    // jumps when the controller commits the new index. With it, the
    // round() of the live animation value picks the closest tab on
    // every frame, so the highlight tracks the swipe exactly like
    // the bottom nav tracks a tap.
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        border: Border(
          bottom: BorderSide(color: scheme.outlineVariant, width: 0.6),
        ),
      ),
      child: AnimatedBuilder(
        animation: controller.animation ?? const AlwaysStoppedAnimation(0.0),
        builder: (context, _) {
          final position = (controller.animation?.value ??
                  controller.index.toDouble())
              .clamp(0.0, (tabs.length - 1).toDouble());
          final activeIndex = position.round();
          return Row(
            children: [
              for (int i = 0; i < tabs.length; i++)
                Expanded(
                  child: _TopTabButton(
                    spec: tabs[i],
                    selected: i == activeIndex,
                    onTap: () => controller.animateTo(i),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _TopTabButton extends StatelessWidget {
  const _TopTabButton({
    required this.spec,
    required this.selected,
    required this.onTap,
  });

  final _TabSpec spec;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final primary = scheme.primary;
    return InkWell(
      onTap: onTap,
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                spec.label,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? primary : scheme.onSurfaceVariant,
                  letterSpacing: 0,
                ),
              ),
              const SizedBox(height: 6),
              // Instant, sharp underline. No animation, no rounded
              // corners — matches the bottom nav's instant feel.
              Container(
                height: 2,
                width: 20,
                color: selected ? primary : Colors.transparent,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────
// Shared doc primitives. Everything else is built from these so the
// page has one consistent visual language.
// ────────────────────────────────────────────────────────────────────────

/// Tag chip — small uppercase label with a tinted background.
class _Tag extends StatelessWidget {
  const _Tag(this.label, {this.color});
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppColors.indigo;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 3,
      ),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: c,
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
          height: 1.0,
        ),
      ),
    );
  }
}

/// Section header — leading icon + title (+ optional subtitle + tag).
/// Matches the rest of the app's section dividers (see email_filters,
/// ai_model, etc.).
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    this.subtitle,
    this.tag,
    this.icon,
  });
  final String title;
  final String? subtitle;
  final String? tag;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(
        top: AppSpacing.lg,
        bottom: AppSpacing.sm,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            Padding(
              padding: const EdgeInsets.only(top: 2, right: AppSpacing.sm),
              child: Icon(icon, size: 16, color: scheme.primary),
            ),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Flexible(
                    child: Text(
                      title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                  if (tag != null) ...[
                    const SizedBox(width: AppSpacing.sm),
                    _Tag(tag!),
                  ],
                ]),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      height: 1.4,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Content card — uses the app's themed Card (border, radius, no
/// shadow). Internal padding stays tight.
class _Card extends StatelessWidget {
  const _Card({required this.child, this.padding = const EdgeInsets.all(AppSpacing.md)});
  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Padding(padding: padding, child: child),
    );
  }
}

/// Flow diagram node — small icon, label, sublabel. Tight, no border
/// chrome; the color hint is the only decoration (a thin tint).
class _FlowNode extends StatelessWidget {
  const _FlowNode({
    required this.label,
    required this.sublabel,
    required this.color,
    this.icon,
  });
  final String label;
  final String sublabel;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm + 2,
        vertical: AppSpacing.sm + 2,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: color),
            const SizedBox(width: AppSpacing.sm),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  sublabel,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// "Label on the edge" caption between flow nodes. Italic + small.
class _FlowArrow extends StatelessWidget {
  const _FlowArrow(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        children: [
          const SizedBox(width: AppSpacing.xs),
          Icon(
            Icons.arrow_downward_rounded,
            size: 14,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: AppSpacing.xs),
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontStyle: FontStyle.italic,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Group container for a stack of flow nodes — title with a colored
/// accent strip + tight padding around the children.
class _GroupCard extends StatelessWidget {
  const _GroupCard({
    required this.title,
    required this.color,
    required this.children,
    this.icon,
  });
  final String title;
  final Color color;
  final List<Widget> children;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: scheme.outlineVariant, width: 0.6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm + 2,
            ),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.06),
              border: Border(
                bottom: BorderSide(
                  color: scheme.outlineVariant,
                  width: 0.6,
                ),
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 3,
                  height: 14,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                if (icon != null) ...[
                  Icon(icon, size: 14, color: color),
                  const SizedBox(width: 6),
                ],
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: color,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.sm + 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (int i = 0; i < children.length; i++) ...[
                  if (i > 0) const SizedBox(height: AppSpacing.xs),
                  children[i],
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact key/value table. First row is the header. Tight vertical
/// rhythm so the cards stay compact.
class _KvTable extends StatelessWidget {
  const _KvTable({required this.rows});
  final List<List<String>> rows; // first row = header

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final headerStyle = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
      letterSpacing: 0.5,
    );
    final cellStyle = theme.textTheme.bodySmall?.copyWith(height: 1.45);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (int i = 0; i < rows.length; i++) ...[
          if (i > 0)
            Divider(
              height: 1,
              thickness: 0.5,
              color: scheme.outlineVariant.withValues(alpha: 0.5),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm + 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (int j = 0; j < rows[i].length; j++)
                  Expanded(
                    flex: j == 0 ? 4 : 5,
                    child: j == 0
                        ? Text(rows[i][j], style: headerStyle)
                        : Text(
                            rows[i][j],
                            style: cellStyle?.copyWith(
                              fontFeatures: const [FontFeature.tabularFigures()],
                            ),
                          ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// Tiny dot + colored label — for "Active / Deleted / Disabled" pills
/// in the services table.
class _StatusPill extends StatelessWidget {
  const _StatusPill(this.label, {this.color});
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppColors.success;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: c, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(
            color: c,
            fontWeight: FontWeight.w700,
            fontSize: 11,
            letterSpacing: 0.2,
          ),
        ),
      ],
    );
  }
}

/// Bullet + text, used inside the "why" card and inside roadmap cards.
class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs + 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Container(
              width: 4,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.amber,
                shape: BoxShape.circle,
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}

/// Scroll viewport with the page's standard gutter + bottom padding
/// that clears the floating bottom nav pill.
class _TabBody extends StatelessWidget {
  const _TabBody({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.pagePadding,
        AppSpacing.sm,
        AppSpacing.pagePadding,
        AppSpacing.xxxl,
      ),
      children: children,
    );
  }
}

// ────────────────────────────────────────────────────────────────────────
// Tab 1 — Flow
// ────────────────────────────────────────────────────────────────────────

class _FlowTab extends StatelessWidget {
  const _FlowTab();

  @override
  Widget build(BuildContext context) {
    return _TabBody(children: [
      _Card(child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Text(
              'Pocket',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            const _Tag('CURRENT'),
          ]),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Personal-finance Android app. Captures transactions from Gmail '
            'in real time (push via Pub/Sub → Oracle VM → FCM), parses them '
            'on-device with the user\'s LLM key, stores them in SQLite, '
            'tracks budgets (with server-side auto-create on the 1st of '
            'every month), has an AI agent. Backups land in Cloudflare R2 '
            '(the object store); Postgres only holds schedule + budget '
            'metadata — backup blobs never touch local disk or the DB.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.5),
          ),
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: 6,
            children: const [
              _Tag('VM 150.136.83.87', color: AppColors.amber),
              _Tag('Oracle Linux 9.8', color: AppColors.amber),
              _Tag('Dart 3.13 / Flutter', color: AppColors.amber),
              _Tag('Postgres 13', color: AppColors.indigo),
              _Tag('Caddy 2 · ZeroSSL', color: AppColors.indigo),
            ],
          ),
        ],
      )),

      const _SectionHeader(
        title: 'System overview',
        subtitle: 'Three systems; the phone never talks to Gmail directly '
            '— only the VM does, with the user\'s OAuth refresh token.',
        icon: Icons.schema_outlined,
      ),
      _Card(padding: const EdgeInsets.all(AppSpacing.md), child: Column(
        children: [
          _GroupCard(
            icon: Icons.smartphone_rounded,
            title: 'Android phone',
            color: AppColors.indigo,
            children: const [
              _FlowNode(
                icon: Icons.dashboard_rounded,
                label: 'Flutter UI (Riverpod)',
                sublabel: 'dashboard · transactions · budgets · agent',
                color: AppColors.indigo,
              ),
              _FlowNode(
                icon: Icons.storage_rounded,
                label: 'SQLite',
                sublabel: 'transactions · budgets · alert_log · ai_log',
                color: AppColors.indigo,
              ),
              _FlowNode(
                icon: Icons.lock_rounded,
                label: 'FlutterSecureStorage',
                sublabel: 'apiToken · LLM keys',
                color: AppColors.indigo,
              ),
              _FlowNode(
                icon: Icons.auto_awesome_rounded,
                label: 'CloudAiParser',
                sublabel: 'openai · anthropic · google · custom',
                color: AppColors.indigo,
              ),
            ],
          ),
          const _FlowArrow('HTTPS + apiToken (HS256 JWT)'),
          _GroupCard(
            icon: Icons.dns_rounded,
            title: 'Oracle VM · 150.136.83.87',
            color: AppColors.amber,
            children: const [
              _FlowNode(
                icon: Icons.shield_rounded,
                label: 'Caddy 2.11',
                sublabel: 'TLS termination (ZeroSSL) · pocket.karmacode.online',
                color: AppColors.amber,
              ),
              _FlowNode(
                icon: Icons.bolt_rounded,
                label: 'pocket-server.service',
                sublabel: 'Dart · shelf · 17 routes · fused with pubsub handler',
                color: AppColors.amber,
              ),
              _FlowNode(
                icon: Icons.dns_rounded,
                label: 'Postgres 13',
                sublabel:
                    'accounts · envelopes (TTL 24h) · filter_rules · budgets · pocket_schedules',
                color: AppColors.amber,
              ),
              _FlowNode(
                icon: Icons.cloud_outlined,
                label: 'Cloudflare R2',
                sublabel: 'pocket-backups / {sub}.json.gz (backup blobs)',
                color: AppColors.amber,
              ),
            ],
          ),
          const _FlowArrow('FCM data messages (per device token)'),
          _GroupCard(
            icon: Icons.cloud_outlined,
            title: 'GCP · pocket-mail-sync',
            color: AppColors.success,
            children: const [
              _FlowNode(
                icon: Icons.swap_horiz_rounded,
                label: 'Pub/Sub · gmail-history',
                sublabel: 'sub gmail-history-sub → push → Caddy → VM',
                color: AppColors.success,
              ),
              _FlowNode(
                icon: Icons.notifications_active_rounded,
                label: 'FCM HTTP v1',
                sublabel: 'project pocket-mail-sync · SA pocket-fcm-publisher@…',
                color: AppColors.success,
              ),
              _FlowNode(
                icon: Icons.vpn_key_rounded,
                label: 'OAuth consent + clients',
                sublabel: 'Web client (server) · Android client (mobile)',
                color: AppColors.success,
              ),
              _FlowNode(
                icon: Icons.fingerprint_rounded,
                label: 'Firebase Auth + Installations',
                sublabel: 'custom-token mint · FIS for FCM device identity',
                color: AppColors.success,
              ),
            ],
          ),
        ],
      )),

      const _SectionHeader(
        title: 'Gmail → notification · end-to-end',
        subtitle: 'The hot path. Latency target ~3 s from email arriving '
            'in the inbox to the phone showing a heads-up.',
        icon: Icons.bolt_rounded,
      ),
      _Card(child: Column(children: [
        for (final entry in _gmailSteps.asMap().entries)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm + 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  margin: const EdgeInsets.only(top: 1),
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    color: AppColors.indigo.withValues(alpha: 0.10),
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      '${entry.key + 1}',
                      style: const TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                        color: AppColors.indigo,
                        height: 1.0,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.value.$1,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          height: 1.25,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        entry.value.$2,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ])),

      const _SectionHeader(
        title: 'Authentication flavors',
        subtitle: 'Six different auth flows live in this stack. Getting '
            'these mixed up is the most common "why isn\'t this working" '
            '— this is the cheat sheet.',
        icon: Icons.vpn_key_rounded,
      ),
      _Card(child: _KvTable(rows: const [
        ['CALLER', 'VERIFIER', 'ALGO'],
        ['Mobile → server REST', 'verifyApiToken', 'HS256 JWT (90 d TTL)'],
        ['Pub/Sub → /pubsub/push', 'verifyPubSubJwt', 'RS256 OIDC (Google)'],
        ['Mobile → /oauth/exchange', 'none — anonymous', 'OAuth 2.0 auth-code'],
        ['Server → FCM / Firebase', 'clientViaServiceAccount', 'OAuth 2.0 SA JSON'],
        ['Server → Gmail (per user)', 'oauth2/token refresh grant', 'refresh_token from PG'],
        ['Mobile → Firebase Auth', 'Google', 'custom token JWT'],
      ])),

      const _SectionHeader(
        title: 'Service accounts · every identity',
        subtitle: 'Three SAs + two OAuth clients + one API key, '
            'intentionally separate so a leaked credential has the '
            'smallest possible blast radius.',
        icon: Icons.shield_moon_rounded,
        tag: 'MATRIX',
      ),
      _Card(child: _KvTable(rows: const [
        ['ACCOUNT', 'WHAT IT DOES'],
        ['pocket-server@…', 'Pub/Sub push OIDC token mint for /pubsub/push. Cloud Run runtime identity (legacy).'],
        ['pocket-fcm-publisher@…', 'Sole SA that calls FCM HTTP v1 messages:send. JSON key at /opt/pocket/secrets/fcm-service-account.json (mode 0400).'],
        ['gmail-api-push@system.gserviceaccount.com', 'Google\'s SA — not ours. Publishes to gmail-history topic. IAM = roles/pubsub.publisher.'],
        ['OAuth Web client', 'ng4mmjfe73l6n19jbnqr1iuc091nl49f… — server-side token exchange (auth-code + refresh grants).'],
        ['OAuth Android client', 'gginrnvmf24nivfbn0ehob20dd6d1urg… — mobile GoogleSignIn; package com.limitless.pocket; SHA-1 a18b8c85…'],
        ['API key (Firebase)', 'AIzaSyBERHOgPvsaUDXUFjwkk5aMSCRnMbjqvEA — mobile talks to FIS + FCM. Lives in google-services.json.'],
      ])),

      const _SectionHeader(
        title: 'Why three SAs + clients',
        subtitle: 'Split for blast radius, not by accident.',
        icon: Icons.help_outline_rounded,
      ),
      _Card(child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const [
          _InfoRow(text: 'FCM publisher can target every Pocket user. Splitting it from pocket-server means an FCM-key leak doesn\'t unlock Pub/Sub push forgery.'),
          _InfoRow(text: 'Web and Android OAuth clients are separate so the consent screen tracks scope-grants separately. The server\'s Web client has a secret; the Android client uses the installed-app flow.'),
          _InfoRow(text: 'Gmail needs gmail-api-push@system.gserviceaccount.com as publisher — we can\'t substitute our own SA.'),
        ],
      )),
    ]);
  }
}

const List<(String, String)> _gmailSteps = [
  ('Gmail user\'s filter matches', 'pocket_label_id applied at SMTP-receive time'),
  ('Pub/Sub topic receives push', 'data = {emailAddress, historyId}'),
  ('VM verifies RS256 OIDC JWT', 'audience = pocket.karmacode.online/pubsub/push'),
  ('VM fetches refresh_token', 'AES-GCM unseal, exchange → access_token'),
  ('VM calls users.history.list', 'startHistoryId = accounts.last_history_id'),
  ('For each new message', 're-issue users.watch if it expired (~7 d)'),
  ('Server-side filter rules', 'body ≤ 4 KB → inline; else store envelope, push truncated marker'),
  ('VM publishes FCM HTTP v1', 'one POST per device token in accounts.fcm_tokens'),
  ('Phone FCM SDK wakes', 'foreground branch: gcm→pipeline; background: separate isolate'),
  ('Phone parses email on-device', 'CloudAiParser: parser_router → LLM key in secure storage'),
  ('Insert into SQLite', 'transactions.notification_key is UNIQUE (no race)'),
  ('Local heads-up fires', 'flutter_local_notifications · Captured from Gmail'),
  ('Phone acks', 'DELETE /envelope?messageId=X → server drops the row'),
];

// ────────────────────────────────────────────────────────────────────────
// Tab 2 — Services
// ────────────────────────────────────────────────────────────────────────

class _ServicesTab extends StatelessWidget {
  const _ServicesTab();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _TabBody(children: [
      const _SectionHeader(
        title: 'GCP services in use',
        subtitle: 'GCP\'s role is now minimal: Pub/Sub (because Gmail '
            'requires it), FCM (free push), OAuth (auth), Firebase Auth '
            '+ Installations (custom-token mint + FCM device identity).',
        icon: Icons.cloud_outlined,
        tag: 'TRIMMED',
      ),
      _Card(child: Column(children: [
        for (final svc in const [
          ('Pub/Sub', 'Active', AppColors.success,
            'Gmail push is GCP-only — no other path exists. Topic gmail-history, sub gmail-history-sub (push).'),
          ('FCM HTTP v1', 'Active', AppColors.success,
            'Push mechanism. Free + no quota worth worrying about. SA: pocket-fcm-publisher@…'),
          ('OAuth (consent + clients)', 'Active', AppColors.success,
            'Mobile Sign-In + server token exchange.'),
          ('Firebase Auth', 'Active', AppColors.success,
            'Server mints custom tokens so the SDK can sign in without us storing Firebase passwords.'),
          ('Firebase Installations', 'Active', AppColors.success,
            'Required for FCM token issuance. Same SA.'),
          ('Service Usage API', 'Active', AppColors.success,
            'Used to enable/disable child APIs (e.g. when we create the API key).'),
          ('Cloud Run', 'Deleted', AppColors.danger,
            'Replaced by Oracle VM (pocket-server.service).'),
          ('Firestore', 'Deleted', AppColors.danger,
            'Replaced by Postgres 13 on VM.'),
          ('Cloud Storage', 'Deleted', AppColors.danger,
            'Replaced by Cloudflare R2 (pocket-backups bucket).'),
          ('Cloud Scheduler', 'Deleted', AppColors.danger,
            'Inline cron in pocket-server (planned).'),
          ('Cloud Build / Artifact Registry', 'Deleted', AppColors.danger,
            'No container deploys from GCP anymore.'),
          ('BigQuery billing export', 'Deleted', AppColors.danger,
            'Cost is near zero — no infra screen to feed.'),
          ('Cloud Trace', 'Disabled', AppColors.amber,
            'gcloud services disable cloudtrace… was a defense-in-depth. Re-enable only if we ever need span traces.'),
        ])
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 5,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Expanded(
                          child: Text(
                            svc.$1,
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        _StatusPill(svc.$2, color: svc.$3),
                      ]),
                      const SizedBox(height: 2),
                      Text(
                        svc.$4,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        Divider(
          height: AppSpacing.lg,
          thickness: 0.6,
          color: scheme.outlineVariant,
        ),
        Padding(
          padding: const EdgeInsets.only(top: AppSpacing.xs),
          child: Text(
            'Total GCP cost is near zero at Pocket\'s scale. Pub/Sub + FCM '
            'are free-tier or near-free. Egress stays tiny because the '
            'Pub/Sub push payload is {messageId, …} (≈100 B), not the '
            'email body.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.45,
              fontStyle: FontStyle.italic,
            ),
          ),
        ),
      ])),
    ]);
  }
}

// ────────────────────────────────────────────────────────────────────────
// Tab 3 — Endpoints & Storage
// ────────────────────────────────────────────────────────────────────────

class _EndpointsStorageTab extends StatelessWidget {
  const _EndpointsStorageTab();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return _TabBody(children: [
      const _SectionHeader(
        title: 'API endpoints',
        subtitle: 'All paths live on https://pocket.karmacode.online. '
            'JSON in / JSON out, except /health.',
        icon: Icons.swap_horiz_rounded,
        tag: '19 ROUTES',
      ),
      _Card(child: Column(children: [
        for (final group in const [
          ('Anonymous', [
            ('GET', '/health', 'returns 200 "ok"'),
          ]),
          ('OAuth (anonymous)', [
            ('POST', '/oauth/exchange', '{serverAuthCode} → {apiToken, email, firebaseCustomToken}'),
            ('POST', '/oauth/signout', 'revokes refresh_token + wipes FCM tokens'),
          ]),
          ('Devices (apiToken)', [
            ('POST', '/devices/register', 'persists FCM token for this account'),
            ('POST', '/devices/signout', 'drops FCM tokens'),
          ]),
          ('Sync (apiToken)', [
            ('GET', '/sync?since=<ms>', 'returns envelopes updated after since'),
            ('GET', '/sync?messageId=<id>', 'returns single envelope (pull path)'),
            ('DELETE', '/envelope?messageId=<id>', 'ack / consume an envelope'),
          ]),
          ('Filter rules (apiToken)', [
            ('POST', '/filters/sync', 'diff-and-apply user filter rules'),
            ('GET', '/filters/status', 'current rules for the sub'),
          ]),
          ('Backup (apiToken)', [
            ('POST', '/backup/upload', '{transactions, budgets} → R2 pocket-backups/{sub}.json.gz'),
            ('GET', '/backup/current', 'latest blob (or 404)'),
            ('POST', '/backup/remove', 'wipes blob'),
          ]),
          ('Budgets (apiToken)', [
            ('GET', '/budgets', 'lists every server-mirrored budget for the sub'),
            ('GET', '/budgets?month=YYYY-MM', 'restricts to a single calendar month'),
            ('GET', '/budgets/ensure-current', 'idempotent — mints "<MonthName> Expenses" for the current month if missing and the user has autoMonthlyBudget=true'),
          ]),
          ('Account (apiToken)', [
            ('GET', '/accounts/<sub>', 'hydrates backupPrefs + budgetPrefs + filterRules + lastSyncAt in one round trip'),
            ('PATCH', '/accounts/<sub>', 'partial update; backupPrefs/budgetPrefs/filterRules/lastSyncAt; false→true budgetPrefs transition triggers ensure-current as a side-effect (returns activatedBudget)'),
            ('POST', '/account/delete', 'wipes account row + tokens'),
          ]),
          ('Pub/Sub push (RS256 OIDC)', [
            ('POST', '/pubsub/push', 'audience = pocket.karmacode.online/pubsub/push'),
          ]),
        ]) ...[
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.md, bottom: AppSpacing.xs),
            child: Text(
              group.$1.toUpperCase(),
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
                letterSpacing: 0.6,
              ),
            ),
          ),
          for (final ep in group.$2)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 52,
                    padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 6),
                    decoration: BoxDecoration(
                      color: AppColors.indigo.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      ep.$1,
                      style: const TextStyle(
                        fontFamily: 'ui-monospace, SF Mono, Menlo, monospace',
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        color: AppColors.indigo,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          ep.$2,
                          style: const TextStyle(
                            fontFamily: 'ui-monospace, SF Mono, Menlo, monospace',
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          ep.$3,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ])),

      const _SectionHeader(
        title: 'Data storage',
        subtitle: 'Where each byte lives. The split is intentional: '
            'SQLite for app-only data, Postgres for server-mediator '
            'state, and Cloudflare R2 for backup blobs.',
        icon: Icons.storage_rounded,
        tag: 'MATRIX',
      ),
      _Card(child: _KvTable(rows: const [
        ['DATA', 'SQLITE', 'POSTGRES', 'CLOUD'],
        ['Transactions', '✓', '—', 'local backup → R2'],
        ['Budgets (device copy)', '✓', '—', 'local backup → R2'],
        ['Budgets (server mirror)', '—', '✓ budgets row (id UUID)', '—'],
        ['Alert log', '✓', '—', '—'],
        ['AI log (≤ 50 rows)', '✓', '—', '—'],
        ['OAuth refresh tokens', '—', '✓ (AES-GCM bytea)', '—'],
        ['Email + lastHistoryId', '—', '✓ accounts', '—'],
        ['Filter rules (source)', '—', '✓ accounts.filter_rules', '—'],
        ['FCM device tokens', '—', '✓ accounts.fcm_tokens[]', '—'],
        ['Backup prefs', '—', '✓ accounts.backup_prefs', '—'],
        ['Budget prefs', '—', '✓ accounts.budget_prefs', '—'],
        ['Backup blob', '—', '—', 'R2 pocket-backups/{sub}.json.gz'],
        ['Gmail envelopes (transient)', '—', '✓ TTL 24 h', '—'],
        ['apiToken', 'secure storage', '—', '—'],
        ['LLM keys', 'secure storage', '—', '—'],
      ])),

      const _SectionHeader(
        title: 'Features · what\'s implemented',
        subtitle: 'By surface. File references are noted inline.',
        icon: Icons.layers_rounded,
      ),
      _Card(child: Column(children: [
        for (final f in const [
          ('Gmail capture', 'Push-delivered. Foreground: fcm_bridge.dart. Background: main.dart. Pull-on-resume: gmailSync.fetchNew on main_shell resume.'),
          ('Budgets', 'Exactly-one-active rule. First-ever auto-activates. Per-budget notification: every-change toggle OR multi-select thresholds (mutually exclusive). Dedupe in alert_log.'),
          ('Auto-monthly budgets', 'Server mints "<MonthName> Expenses" on the 1st (systemd timer), on sign-in (mobile hydrator), and on Settings → flip-ON (PATCH side-effect). Amount carries from previous month\'s auto budget, or 0 if none. Auto-activates when no active budget exists. Per-user toggle on Settings → Budgets (default OFF — opt-in). Flipping OFF is non-destructive: pre-existing budgets are never deleted or modified.'),
          ('Transactions', 'UNIQUE notification_key for capture race-safety. Ignore flag excluded from SUM(amount). Bulk delete + CSV export with date filter.'),
          ('AI agent', 'Single-shot structured-intent (no tool loop). 28 verbs. Destructive verbs require a type-confirm modal (delete / disconnect / replace / reset). 30 s snapshot cache.'),
          ('Filter rules', 'FilterRuleSet { enabled, logic, rules }. Within rule = AND, across rules = logic decides. Server diff-then-apply on save.'),
          ('Backup', 'Cloudflare R2 only — server boot fails fast if any R2_* env is missing; no local-disk fallback. PUT overwrites atomically (one blob per sub). Sign-out + /backup/remove both call the same remove path.'),
          ('Three sign-out flavors', 'Back up then sign out / delete backup then sign out / just sign out. Server-side effects run before local wipe.'),
          ('Delete account', '24-hour freshness gate before cloud-side delete. Type "DELETE" to confirm.'),
        ])
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 3,
                  height: 22,
                  margin: const EdgeInsets.only(top: 3, right: AppSpacing.sm),
                  decoration: BoxDecoration(
                    color: AppColors.amber,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        f.$1,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        f.$2,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ])),
    ]);
  }
}

// ────────────────────────────────────────────────────────────────────────
// End of file. Tab 4 (Roadmap) and _RoadmapCard were removed on
// 2026-09-11 — every item that used to live there is now either shipped
// (and listed under "Features · what's implemented") or consciously
// dropped. New work continues to land directly in the docs above.
// ────────────────────────────────────────────────────────────────────────