import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/features/features.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'topology.dart';
import 'connection_poller.dart';

enum _RequestStatus { all, active, failed }

class RequestsView extends ConsumerStatefulWidget {
  final ScrollController? scrollController;
  final RequestFeed? initialFeed;
  final bool initialTopology;
  final Future<List<TrackerInfo>> Function()? connectionsReader;

  const RequestsView({
    super.key,
    this.scrollController,
    this.initialFeed,
    this.initialTopology = false,
    @visibleForTesting this.connectionsReader,
  });

  @override
  ConsumerState<RequestsView> createState() => _RequestsViewState();
}

class _RequestsViewState extends ConsumerState<RequestsView>
    with RouteMotionHoldMixin<RequestsView> {
  final _recent = TrackerInfoListController();
  final _live = TrackerInfoListController();
  final _liveFeed = GlobalKey<_LiveFeedState>();
  late bool _showTopology = widget.initialTopology;
  var _showDns = false;
  var _query = '';
  late final _filters = trackerInfoFilterController(ref, 'requests');
  late final _dnsFilters = RecordFilterController<DnsQuery>(
    facets: dnsQueryFacets,
  );
  late var _feed = widget.initialTopology
      ? RequestFeed.live
      : widget.initialFeed ?? ref.read(appSettingProvider).requestFeed;

  @override
  void initState() {
    super.initState();
    if (_feed == RequestFeed.recent) {
      _showLatestRequests();
    }
    _dnsFilters.offer(ref.read(dnsQueriesProvider).list);
    ref.listenManual(requestsProvider.select((state) => state.revision), (
      _,
      _,
    ) {
      updateRequestsThrottler();
    });
    ref.listenManual(dnsQueriesProvider.select((state) => state.revision), (
      _,
      _,
    ) {
      if (!_showDns) {
        return;
      }
      throttler.call(FunctionTag.dnsQueries, () {
        if (mounted && _showDns) {
          updateWhenRouteSettled(_offerDnsQueries);
        }
      }, duration: renderThrottleDuration);
    });
  }

  @override
  void dispose() {
    _recent.dispose();
    _live.dispose();
    _filters.dispose();
    _dnsFilters.dispose();
    super.dispose();
  }

  void _setRequests(List<TrackerInfo> requests) {
    _recent.setTrackerInfos(requests);
    _filters.offer(_recent.value.trackerInfos);
  }

  void _showLatestRequests() {
    _recent.resumeAutoScrollToEnd(ref.read(requestsProvider).list);
    _filters.offer(_recent.value.trackerInfos);
  }

  void updateRequestsThrottler() {
    throttler.call(FunctionTag.requests, () {
      if (!mounted || _feed != RequestFeed.recent) {
        return;
      }
      updateWhenRouteSettled(
        () => _setRequests(ref.read(requestsProvider).list),
      );
    }, duration: renderThrottleDuration);
  }

  void _offerDnsQueries() {
    _dnsFilters.offer(ref.read(dnsQueriesProvider).list);
  }

  void _showDnsQueries() {
    if (_showDns) {
      return;
    }
    _offerDnsQueries();
    setState(() {
      _showDns = true;
      _showTopology = false;
    });
  }

  void _search(String query) {
    _query = query;
    _recent.search(query);
    _live.search(query);
    if (_showDns) {
      setState(() {});
    }
  }

  void _selectFeed(RequestFeed feed) {
    if (feed == _feed && !_showTopology && !_showDns) {
      return;
    }
    // Offered before the feed mounts: a build below this page can't notify it.
    if (feed == RequestFeed.recent) {
      _showLatestRequests();
    }
    setState(() {
      _feed = feed;
      _showTopology = false;
      _showDns = false;
    });
    if (widget.initialFeed == null) {
      ref
          .read(appSettingProvider.notifier)
          .update((state) => state.copyWith(requestFeed: feed));
    }
  }

  List<IconButtonData> _buildActions() {
    if (_showDns || _feed != RequestFeed.live || _showTopology) {
      return const [];
    }
    return [
      IconButtonData(
        glyph: AppGlyphs.clearAll,
        tooltip: context.appLocalizations.closeConnections,
        onPressed: () => _liveFeed.currentState?.closeAll(),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final activeFilters = _showDns ? _dnsFilters : _filters;
    final body = RecordFilterScope(
      onFilter: activeFilters.add,
      child: ListenableBuilder(
        listenable: activeFilters,
        builder: (_, _) => _buildBody(),
      ),
    );
    return ListenableBuilder(
      listenable: Listenable.merge([
        _filters,
        _filters.options,
        _dnsFilters,
        _dnsFilters.options,
      ]),
      child: body,
      builder: (context, body) {
        final pinned = !ViewScope.isMobileOf(context);
        final activeFilters = _showDns ? _dnsFilters : _filters;
        return Scaffold(
          title: _showDns
              ? context.appLocalizations.dnsQueries
              : _showTopology
              ? topologyTitle(context)
              : _labelOf(_feed),
          titleMenuItems: _buildFeedMenu(),
          searchState: AppBarSearchState(onSearch: _search),
          keywords: activeFilters.keywordsOf(pinned: pinned),
          iconActions: _buildActions(),
          menuItems: activeFilters.menuItems(context, pinned: pinned),
          body: body!,
        );
      },
    );
  }

  String _labelOf(RequestFeed feed) => switch (feed) {
    RequestFeed.recent => context.appLocalizations.recentRequests,
    RequestFeed.live => context.appLocalizations.running,
  };

  List<PopupMenuItem> _buildFeedMenu() {
    return [
      for (final feed in RequestFeed.values)
        PopupMenuItem(
          label: _labelOf(feed),
          checked: feed == _feed && !_showTopology && !_showDns,
          onPressed: () => _selectFeed(feed),
        ),
      PopupMenuItem(
        label: context.appLocalizations.dnsQueries,
        checked: _showDns,
        onPressed: _showDnsQueries,
      ),
      PopupMenuItem(
        label: topologyTitle(context),
        checked: _showTopology,
        onPressed: () {
          if (_showTopology) return;
          _selectFeed(RequestFeed.live);
          setState(() => _showTopology = true);
        },
      ),
    ];
  }

  Widget _buildBody() {
    if (_showDns) {
      return DnsQueriesFeed(
        query: _query,
        filters: _dnsFilters,
        scrollController: widget.scrollController,
      );
    }
    return switch (_feed) {
      RequestFeed.recent => _RecentFeed(
        listController: _recent,
        filters: _filters,
        scrollController: widget.scrollController,
        onResumeToEnd: _showLatestRequests,
      ),
      RequestFeed.live => _LiveFeed(
        key: _liveFeed,
        listController: _live,
        filters: _filters,
        scrollController: widget.scrollController,
        connectionsReader: widget.connectionsReader,
        showTopology: _showTopology,
      ),
    };
  }
}

class _RecentFeed extends ConsumerStatefulWidget {
  final TrackerInfoListController listController;
  final RecordFilterController<TrackerInfo> filters;
  final ScrollController? scrollController;
  final VoidCallback onResumeToEnd;

  const _RecentFeed({
    required this.listController,
    required this.filters,
    required this.scrollController,
    required this.onResumeToEnd,
  });

  @override
  ConsumerState<_RecentFeed> createState() => _RecentFeedState();
}

class _RecentFeedState extends ConsumerState<_RecentFeed> {
  var _status = _RequestStatus.all;
  late final ScrollController _scrollController;
  late final _physics = FollowEndScrollPhysics(
    isFollowing: () => widget.listController.value.autoScrollToEnd,
  );

  @override
  void initState() {
    super.initState();
    _scrollController =
        widget.scrollController ??
        sheetScrollController(context, initialScrollOffset: double.maxFinite);
    // A sheet's one controller may have been left where the live feed reads.
    if (widget.scrollController != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scrollController.hasClients) {
          _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
        }
      });
    }
  }

  @override
  void dispose() {
    if (widget.scrollController == null) {
      _scrollController.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    final counts = ref.watch(
      requestsProvider.select(
        (log) => (
          total: log.length,
          active: log.activeCount,
          failed: log.failedCount,
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: SegmentedControl<_RequestStatus>(
            segments: [
              (_RequestStatus.all, 'All ${counts.total}'),
              (
                _RequestStatus.active,
                '${appLocalizations.running} ${counts.active}',
              ),
              (_RequestStatus.failed, 'Failed ${counts.failed}'),
            ],
            value: _status,
            onChanged: (value) => setState(() => _status = value),
          ),
        ),
        Expanded(
          child: ValueListenableBuilder<TrackerInfosState>(
            valueListenable: widget.listController,
            builder: (context, state, _) {
              final candidates = switch (_status) {
                _RequestStatus.all => state.list,
                _RequestStatus.active =>
                  state.list.where((request) => request.isActive).toList(),
                _RequestStatus.failed =>
                  state.list
                      .where((request) => request.failure != null)
                      .toList(),
              };
              final requests = widget.filters.apply(candidates);
              return NullStatusSwitcher(
                isEmpty: requests.isEmpty,
                isSearching: state.isSearching || widget.filters.isFiltering,
                nullStatus: NullStatus(
                  label: appLocalizations.nullTip(appLocalizations.requests),
                  illustration: NullStatusIllustration.requests,
                ),
                child: RecordTableFrame<TrackerInfo>(
                  tableId: 'requests',
                  items: requests,
                  reverse: true,
                  columnsOf: (width) =>
                      trackerInfoColumns(context, width: width, isLive: false),
                  builder: (context, table, requests) {
                    final padding = EdgeInsets.only(
                      top: context.contentTopPadding,
                      bottom: 16 + context.bottomInset,
                    );
                    final detailTitle = appLocalizations.details(
                      appLocalizations.request,
                    );
                    final groups = widget.filters.groupsOf(
                      requests,
                      reverse: true,
                    );
                    if (groups != null) {
                      return FloatingScrollbar(
                        controller: _scrollController,
                        hintBuilder: (fraction) {
                          final index = (fraction * (groups.length - 1))
                              .round();
                          return groups[index].items.first.start.showFull;
                        },
                        child: TrackerInfoGroupedList(
                          groups: groups,
                          grouping: widget.filters.value.grouping!,
                          isLive: false,
                          controller: _scrollController,
                          padding: padding,
                          table: table,
                          detailTitle: detailTitle,
                        ),
                      );
                    }
                    return Align(
                      alignment: Alignment.topCenter,
                      child: FloatingScrollbar(
                        controller: _scrollController,
                        hintBuilder: (fraction) {
                          final index = (fraction * (requests.length - 1))
                              .round();
                          return requests[index].start.showFull;
                        },
                        child: ScrollToEndBox(
                          controller: _scrollController,
                          enable: state.autoScrollToEnd,
                          onCancelToEnd: () {
                            widget.listController.setAutoScrollToEnd(false);
                          },
                          onResumeToEnd: () {
                            widget.onResumeToEnd();
                          },
                          child: TrackerInfoList(
                            reverse: true,
                            shrinkWrap: true,
                            physics: _physics,
                            controller: _scrollController,
                            padding: padding,
                            trackerInfos: requests,
                            table: table,
                            detailTitle: detailTitle,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _LiveFeed extends ConsumerStatefulWidget {
  final TrackerInfoListController listController;
  final RecordFilterController<TrackerInfo> filters;
  final ScrollController? scrollController;
  final Future<List<TrackerInfo>> Function()? connectionsReader;

  final bool showTopology;

  const _LiveFeed({
    super.key,
    required this.listController,
    required this.filters,
    required this.scrollController,
    required this.connectionsReader,
    required this.showTopology,
  });

  @override
  ConsumerState<_LiveFeed> createState() => _LiveFeedState();
}

class _LiveFeedState extends ConsumerState<_LiveFeed>
    with
        WidgetsBindingObserver,
        ActivePollingMixin<_LiveFeed>,
        RouteMotionHoldMixin<_LiveFeed> {
  CoreController get _core => ref.read(coreHandlerProvider);

  final _connectionPoller = ConnectionPoller();
  late final ScrollController _scrollController;
  var _loaded = false;
  // A sheet's one controller opens where the recent feed reads, its far end.
  late var _startsAtFarEnd = widget.scrollController != null;

  @override
  void initState() {
    super.initState();
    _scrollController =
        widget.scrollController ?? sheetScrollController(context);
  }

  @override
  Duration get pollInterval => const Duration(seconds: 1);

  Future<void> closeAll() => _close(_core.closeConnections);

  List<TrackerInfo> _openConnections() => [
    for (final connection in ref.read(requestsProvider).list)
      if (connection.isActive) connection,
  ];

  @override
  Future<void> poll(PollGuard isCurrent) async {
    await _connectionPoller.read(
      ref,
      reader: widget.connectionsReader,
      mounted: () => mounted,
    );
    if (!isCurrent()) {
      return;
    }
    _showConnections(_openConnections());
  }

  Future<void> _refreshConnections() async {
    await _connectionPoller.read(
      ref,
      reader: widget.connectionsReader,
      mounted: () => mounted,
    );
    if (!mounted) {
      return;
    }
    _showConnections(_openConnections());
  }

  void _showConnections(List<TrackerInfo>? trackerInfos) {
    if (!_loaded) {
      showFirstContent(() {
        setState(() => _loaded = true);
        // A failed read must not leave the controller's list from the last visit.
        _applyConnections(trackerInfos ?? const []);
      });
      return;
    }
    updateWhenRouteSettled(() => _applyConnections(trackerInfos));
  }

  void _applyConnections(List<TrackerInfo>? trackerInfos) {
    if (trackerInfos == null) {
      return;
    }
    widget.listController.setTrackerInfos(trackerInfos);
    widget.filters.offer(widget.listController.value.trackerInfos);
    if (_startsAtFarEnd) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _startsAtFarEnd && _scrollController.hasClients) {
          _startsAtFarEnd = false;
          _scrollController.jumpTo(0);
        }
      });
    }
  }

  Future<void> _closeConnection(TrackerInfo trackerInfo) =>
      _close(() => _core.closeConnection(trackerInfo.id));

  Future<void> _close(Future<void> Function() close) async {
    await globalState.safeRun(close, title: 'close connections');
    if (mounted) {
      await _refreshConnections();
    }
  }

  @override
  void dispose() {
    if (widget.scrollController == null) {
      _scrollController.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    return ValueListenableBuilder<TrackerInfosState>(
      valueListenable: widget.listController,
      builder: (context, state, _) {
        final connections = widget.filters.apply(state.list);
        if (widget.showTopology && _loaded) {
          return ConnectionTopology(
            connections: connections,
            controller: _scrollController,
            padding: EdgeInsets.only(
              top: context.contentTopPadding,
              bottom: 16 + context.bottomInset,
            ),
          );
        }
        return NullStatusSwitcher(
          isLoading: !_loaded,
          loadingStatus: const Center(child: ActivityIndicator.page()),
          isEmpty: connections.isEmpty,
          isSearching: state.isSearching || widget.filters.isFiltering,
          nullStatus: NullStatus(
            label: appLocalizations.nullTip(appLocalizations.connections),
            illustration: NullStatusIllustration.connections,
          ),
          child: RecordTableFrame<TrackerInfo>(
            tableId: 'connections',
            items: connections,
            columnsOf: (width) =>
                trackerInfoColumns(context, width: width, isLive: true),
            builder: (context, table, connections) {
              final padding = EdgeInsets.only(
                top: context.contentTopPadding,
                bottom: 16 + context.bottomInset,
              );
              final detailTitle = appLocalizations.details(
                appLocalizations.connection,
              );
              final groups = widget.filters.groupsOf(connections);
              if (groups != null) {
                return TrackerInfoGroupedList(
                  groups: groups,
                  grouping: widget.filters.value.grouping!,
                  isLive: true,
                  controller: _scrollController,
                  padding: padding,
                  table: table,
                  detailTitle: detailTitle,
                  onClose: _closeConnection,
                );
              }
              return TrackerInfoAnimatedList(
                controller: _scrollController,
                padding: padding,
                trackerInfos: connections,
                table: table,
                detailTitle: detailTitle,
                onClose: _closeConnection,
              );
            },
          ),
        );
      },
    );
  }
}
