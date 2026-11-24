import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/views/proxies/list.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'common.dart';
import 'tab.dart';

class ProxiesView extends ConsumerStatefulWidget {
  const ProxiesView({super.key, this.picker = false});

  /// Leaves the bar only its search and delay test, for picking a proxy from a
  /// sheet.
  final bool picker;

  @override
  ConsumerState<ProxiesView> createState() => _ProxiesViewState();
}

class _ProxiesViewState extends ConsumerState<ProxiesView> {
  final GlobalKey<ProxiesTabViewState> _proxiesTabKey = GlobalKey();

  // The same instance on every build, so the bar changing with the current
  // group or its delay test leaves the page alone.
  late final _tabView = ProxiesTabView(key: _proxiesTabKey);
  bool _isTab = false;

  void _updateStyle(
    ProxiesStyleProps Function(ProxiesStyleProps state) update,
  ) {
    ref.read(proxiesStyleSettingProvider.notifier).update(update);
  }

  List<PopupMenuItem> _buildMenuItems(
    BuildContext context,
    ProxiesStyleProps style,
  ) {
    final appLocalizations = context.appLocalizations;
    final autoGroup = ref.watch(downloadSpeedAutoGroupProvider);
    final autoGroups = ref
        .watch(groupsProvider)
        .where(
          (group) => group.type == GroupType.URLTest && group.hidden != true,
        )
        .toList();
    final action = ref.read(proxiesActionProvider.notifier);
    return [
      _optionsMenuItem(
        glyph: AppGlyphs.appsList,
        label: appLocalizations.style,
        section: const PopupMenuSection(),
        options: ProxiesType.values,
        value: style.type,
        textOf: (type) => type.label,
        onSelected: (type) =>
            _updateStyle((state) => state.copyWith(type: type)),
      ),
      _optionsMenuItem(
        glyph: AppGlyphs.sort,
        label: appLocalizations.sort,
        options: ProxiesSortType.values,
        value: style.sortType,
        textOf: (type) => switch (type) {
          ProxiesSortType.none => appLocalizations.defaultText,
          ProxiesSortType.delay => appLocalizations.delay,
          ProxiesSortType.name => appLocalizations.name,
          ProxiesSortType.speed => '下载速度',
        },
        onSelected: (type) =>
            _updateStyle((state) => state.copyWith(sortType: type)),
      ),
      if (autoGroups.isNotEmpty || autoGroup != null)
        PopupMenuItem(
          glyph: AppGlyphs.speed,
          label: '智能节点优选（本次运行）',
          subItems: [
            PopupMenuItem(
              label: '关闭',
              checked: autoGroup == null,
              onPressed: () => action.setDownloadSpeedAutoGroup(null),
            ),
            for (final group in autoGroups)
              PopupMenuItem(
                label: group.name,
                checked: autoGroup == group.name,
                onPressed: () => action.setDownloadSpeedAutoGroup(group.name),
              ),
          ],
        ),
      if (autoGroup != null)
        PopupMenuItem(
          glyph: AppGlyphs.speed,
          label: Localizations.localeOf(context).languageCode == 'zh'
              ? '节点质量统计'
              : 'Node quality statistics',
          onPressed: () {
            final quality = action.nodeProbeQuality;
            final speeds = ref.read(downloadSpeedSortSnapshotProvider);
            showSnapSheet(
              context,
              initialScrollOffset: 0,
              builder: (_, controller) => NestedPagedSheet(
                builder: (_) => _NodeQualitySnapshot(
                  controller: controller,
                  quality: quality,
                  speeds: speeds,
                ),
              ),
            );
          },
        ),
      _optionsMenuItem(
        glyph: AppGlyphs.dashboard,
        label: appLocalizations.layout,
        options: ProxiesLayout.values,
        value: style.layout,
        textOf: (layout) => switch (layout) {
          ProxiesLayout.tight => appLocalizations.tight,
          ProxiesLayout.standard => appLocalizations.standard,
          ProxiesLayout.loose => appLocalizations.loose,
        },
        onSelected: (layout) =>
            _updateStyle((state) => state.copyWith(layout: layout)),
      ),
      _optionsMenuItem(
        glyph: AppGlyphs.textSize,
        label: appLocalizations.size,
        options: ProxyCardType.values,
        value: style.cardType,
        textOf: (type) => type.label,
        onSelected: (type) =>
            _updateStyle((state) => state.copyWith(cardType: type)),
      ),
      if (style.type == ProxiesType.list)
        _optionsMenuItem(
          glyph: AppGlyphs.iconTile,
          label: appLocalizations.iconStyle,
          options: ProxiesIconStyle.values,
          value: style.iconStyle,
          textOf: (iconStyle) => switch (iconStyle) {
            ProxiesIconStyle.filled => appLocalizations.iconStyleFilled,
            ProxiesIconStyle.plain => appLocalizations.iconStylePlain,
            ProxiesIconStyle.hidden => appLocalizations.iconStyleHidden,
          },
          onSelected: (iconStyle) =>
              _updateStyle((state) => state.copyWith(iconStyle: iconStyle)),
        ),
      PopupMenuItem(
        glyph: AppGlyphs.eyeOff,
        label: appLocalizations.hideTimeoutProxies,
        checked: style.hideTimeoutProxies,
        section: const PopupMenuSection(),
        onPressed: () => _updateStyle(
          (state) =>
              state.copyWith(hideTimeoutProxies: !state.hideTimeoutProxies),
        ),
      ),
    ];
  }

  IconButtonData? _buildPrimaryAction() {
    if (!_isTab) {
      return null;
    }
    final isDelayTesting = ref.watch(currentGroupDelayTestingProvider);
    return IconButtonData(
      glyph: AppGlyphs.bolt,
      onPressed: () {
        _proxiesTabKey.currentState?.delayTestCurrentGroup(
          delayOnly: widget.picker,
        );
      },
      tooltip: widget.picker
          ? context.appLocalizations.delayTest
          : '测试延迟及下载速度（先延迟，后逐个下载测速）',
      isLoading: isDelayTesting,
    );
  }

  void _onSearch(String value) {
    ref.read(queryProvider(QueryTag.proxies).notifier).value = value;
  }

  @override
  void initState() {
    super.initState();
    ref.listenManual(
      proxiesStyleSettingProvider.select(
        (state) => state.type == ProxiesType.tab,
      ),
      (prev, next) {
        if (prev != next) {
          setState(() {
            _isTab = next;
          });
        }
      },
      fireImmediately: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final style = ref.watch(proxiesStyleSettingProvider);
    final isLoading = ref.watch(loadingProvider(LoadingTag.proxies));
    final picker = widget.picker;
    final primaryAction = _buildPrimaryAction();
    return Scaffold(
      isLoading: isLoading,
      resizeToAvoidBottomInset: false,
      primaryAction: primaryAction,
      searchActions: [?primaryAction],
      iconActions: [
        if (_isTab && !picker)
          IconButtonData(
            glyph: AppGlyphs.speed,
            onPressed: () {
              final group = _proxiesTabKey.currentState?.currentGroup;
              if (group == null) return;
              ref
                  .read(proxiesActionProvider.notifier)
                  .selectByDownloadSpeed(group.name);
            },
            tooltip: '按真实下载速度选最快节点（消耗测试流量）',
            isLoading: ref.watch(currentGroupDelayTestingProvider),
          ),
        if (_isTab && !picker)
          IconButtonData(
            glyph: AppGlyphs.locate,
            onPressed: () {
              _proxiesTabKey.currentState?.scrollToGroupSelected();
            },
            tooltip: context.appLocalizations.scrollToSelected,
          ),
      ],
      menuItems: picker ? const [] : _buildMenuItems(context, style),
      title: context.appLocalizations.proxies,
      searchState: AppBarSearchState(onSearch: _onSearch),
      body: ProxyPickerScope(
        delayOnly: picker,
        child: switch (style.type) {
          ProxiesType.tab => _tabView,
          ProxiesType.list => const ProxiesListView(),
        },
      ),
    );
  }
}

PopupMenuItem _optionsMenuItem<T>({
  required Glyph glyph,
  required String label,
  required List<T> options,
  required T value,
  required String Function(T option) textOf,
  required ValueSetter<T> onSelected,
  PopupMenuSection? section,
}) {
  return PopupMenuItem(
    glyph: glyph,
    label: label,
    section: section,
    subItems: [
      for (final option in options)
        PopupMenuItem(
          label: textOf(option),
          checked: option == value,
          onPressed: () => onSelected(option),
        ),
    ],
  );
}

/// On-demand snapshot of existing smart-selection samples; never starts probes.
class _NodeQualitySnapshot extends StatelessWidget {
  const _NodeQualitySnapshot({
    required this.controller,
    required this.quality,
    required this.speeds,
  });

  final ScrollController controller;
  final Map<String, NodeProbeQuality> quality;
  final Map<String, int> speeds;

  @override
  Widget build(BuildContext context) {
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    final entries = quality.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    String milliseconds(double? value) =>
        value == null ? '—' : '${value.toStringAsFixed(1)} ms';
    return Scaffold(
      title: zh ? '节点质量统计' : 'Node quality statistics',
      body: ListView.builder(
        controller: controller,
        padding: EdgeInsets.fromLTRB(
          16,
          context.contentTopPadding,
          16,
          16 + context.bottomInset,
        ),
        itemCount: entries.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(
                entries.isEmpty
                    ? (zh ? '暂无智能优选探测记录' : 'No smart-selection samples yet')
                    : (zh
                          ? '本次运行快照 · 每个节点最近 12 次有效 HTTP 探测'
                          : 'Session snapshot · last 12 completed HTTP probes per node'),
              ),
            );
          }
          final entry = entries[index - 1];
          final sample = entry.value;
          final rate = sample.successRate;
          final success = rate == null ? '—' : '${(rate * 100).round()}%';
          final speed = speeds[entry.key];
          return Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 4,
              children: [
                Text(
                  entry.key,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                Text(
                  '${zh ? '探测成功率' : 'Probe success'}: $success '
                  '(${sample.successes}/${sample.values.length})',
                ),
                if (sample.values.isNotEmpty)
                  Semantics(
                    label: zh
                        ? '探测历史，从旧到新'
                        : 'Probe history, oldest first',
                    value: sample.values
                        .map(
                          (value) => value > 0
                              ? '${value} ms'
                              : (zh ? '失败' : 'Failed'),
                        )
                        .join(', '),
                    child: Row(
                      spacing: 3,
                      children: [
                        for (final value in sample.values)
                          Expanded(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: value > 0
                                    ? context.colorScheme.success
                                    : context.colorScheme.error,
                                borderRadius: BorderRadius.circular(3),
                              ),
                              child: const SizedBox(height: 8),
                            ),
                          ),
                      ],
                    ),
                  ),
                Text(
                  '${zh ? '平均延迟' : 'Mean delay'}: '
                  '${milliseconds(sample.meanDelay)}',
                ),
                Text(
                  '${zh ? '延迟波动' : 'Delay variation'}: '
                  '${milliseconds(sample.delayVariation)}',
                ),
                Text(
                  '${zh ? '最近下载测速' : 'Last download test'}: '
                  '${speed == null ? '—' : speed <= 0 ? (zh ? '失败' : 'Failed') : formatDownloadSpeed(speed)}',
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
