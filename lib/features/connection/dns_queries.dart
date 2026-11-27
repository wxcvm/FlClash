import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'dns_query_detail.dart';

/// The DNS events already collected by Core, presented beside recent and live
/// connections without changing the fork's existing request feeds.
class DnsQueriesFeed extends ConsumerStatefulWidget {
  final String query;
  final RecordFilterController<DnsQuery> filters;
  final ScrollController? scrollController;

  const DnsQueriesFeed({
    super.key,
    required this.query,
    required this.filters,
    this.scrollController,
  });

  @override
  ConsumerState<DnsQueriesFeed> createState() => _DnsQueriesFeedState();
}

class _DnsQueriesFeedState extends ConsumerState<DnsQueriesFeed> {
  late final ScrollController _scrollController =
      widget.scrollController ?? sheetScrollController(context);

  @override
  void initState() {
    super.initState();
    if (widget.scrollController != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scrollController.hasClients) {
          _scrollController.jumpTo(0);
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
    final allQueries = ref.watch(dnsQueriesProvider).list;
    final search = SearchQuery(widget.query);
    final searched = search.isEmpty
        ? allQueries
        : allQueries
              .whereMatches(search, (query) => query.searchFields)
              .toList();
    final filtered = widget.filters.apply(searched);
    final newestFirst = filtered.reversed.toList(growable: false);

    return NullStatusSwitcher(
      isEmpty: newestFirst.isEmpty,
      isSearching: search.isNotEmpty || widget.filters.isFiltering,
      nullStatus: NullStatus(
        label: appLocalizations.nullTip(appLocalizations.dnsQueries),
        illustration: NullStatusIllustration.dns,
      ),
      child: FloatingScrollbar(
        controller: _scrollController,
        hintBuilder: (fraction) {
          if (newestFirst.isEmpty) {
            return '';
          }
          final index = (fraction * (newestFirst.length - 1)).round();
          return newestFirst[index].time.showFull;
        },
        child: RecordFeedList<DnsQuery>(
          controller: _scrollController,
          padding: EdgeInsets.only(
            top: context.contentTopPadding,
            bottom: 16 + context.bottomInset,
          ),
          items: newestFirst,
          keyOf: ObjectKey.new,
          gap: recordListGap,
          estimatedItemExtent: recordListEstimatedExtent,
          itemBuilder: (query, _, __) => DnsQueryItem(query: query),
        ),
      ),
    );
  }
}

class DnsQueryItem extends StatelessWidget {
  final DnsQuery query;

  const DnsQueryItem({super.key, required this.query});

  void _filter(BuildContext context, RecordFacetKind kind, String value) {
    RecordFilterScope.add(context, RecordFilter(kind, value));
  }

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    final styles = RecordTextStyles.of(context);
    final initiator = query.initiator;
    final failed = query.isFailed;
    final outcome = query.error.isNotEmpty
        ? query.error
        : failed
        ? query.rcode
        : query.summary;

    return RecordListItem(
      onTap: () => showDnsQueryDetail(context, query),
      header: RecordHeader(
        children: [
          RecordTimestamp(query.time.showFull),
          RecordLabel(
            label: query.type.toUpperCase(),
            onPressed: () => _filter(context, RecordFacetKind.type, query.type),
          ),
          if (initiator != null)
            RecordLabel(
              label: initiator.label,
              onPressed: () =>
                  _filter(context, RecordFacetKind.initiator, initiator.label),
            ),
          if (query.cached)
            RecordLabel(
              label: appLocalizations.cache,
              onPressed: () => _filter(
                context,
                RecordFacetKind.cache,
                appLocalizations.cache,
              ),
            ),
          if (query.hasFailureRcode)
            RecordLabel(
              label: query.rcode,
              tone: RecordTone.error,
              onPressed: () =>
                  _filter(context, RecordFacetKind.rcode, query.rcode),
            ),
        ],
        trailing: Text('${query.delay} ms', style: styles.secondary.toTabular),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 4,
        children: [
          Text(query.domain, style: styles.title),
          if (outcome.isNotEmpty)
            Text(
              outcome,
              style: failed
                  ? styles.secondary.copyWith(color: context.colorScheme.error)
                  : styles.secondary,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
    );
  }
}
