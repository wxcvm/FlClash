import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/widgets.dart';

void showDnsQueryDetail(BuildContext context, DnsQuery dnsQuery) {
  final title = context.appLocalizations.details(
    context.appLocalizations.dnsQueries,
  );
  showSheet<void>(
    context: context,
    props: nestedPagedSheetProps,
    builder: (_) => NestedPagedSheet(
      builder: (_) => Scaffold(
        body: _DnsQueryDetailView(dnsQuery: dnsQuery),
        title: title,
      ),
    ),
  );
}

class _DnsQueryDetailView extends StatelessWidget {
  final DnsQuery dnsQuery;

  const _DnsQueryDetailView({required this.dnsQuery});

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    final initiator = dnsQuery.initiator;
    final margin = context.listInsets.margin;

    return ListView(
      padding: EdgeInsets.fromLTRB(
        margin,
        context.contentTopPadding,
        margin,
        16 + context.bottomInset,
      ),
      children: [
        RecordListItem(
          header: RecordHeader(
            children: [
              RecordTimestamp(dnsQuery.time.showFull),
              RecordLabel(label: dnsQuery.type.toUpperCase()),
              if (initiator != null) RecordLabel(label: initiator.label),
            ],
            trailing: Text('\${dnsQuery.delay} ms'),
          ),
          body: Text(
            dnsQuery.domain,
            style: RecordTextStyles.of(context).title,
          ),
        ),
        DetailRow.text(
          title: appLocalizations.recordType,
          value: dnsQuery.type,
        ),
        if (initiator != null)
          DetailRow.text(
            title: appLocalizations.initiator,
            value: initiator.label,
          ),
        DetailRow.text(
          title: appLocalizations.cache,
          value: dnsQuery.cached ? appLocalizations.yes : appLocalizations.no,
        ),
        if (dnsQuery.rcode.isNotEmpty)
          DetailRow.text(
            title: appLocalizations.responseCode,
            value: dnsQuery.rcode,
          ),
        if (dnsQuery.error.isNotEmpty)
          DetailRow.text(title: appLocalizations.error, value: dnsQuery.error),
        if (dnsQuery.answers.isNotEmpty)
          DetailRow.text(
            title: appLocalizations.answers,
            value: dnsQuery.answers.join('\n'),
          ),
      ],
    );
  }
}
