// ignore_for_file: non_constant_identifier_names

import 'package:flutter/material.dart';
import 'package:karing/app/utils/singbox_json.dart';
import 'package:karing/i18n/strings.g.dart';
import 'package:karing/screens/group_item_creator.dart';
import 'package:karing/screens/group_item_options.dart';

enum SingboxOutboundType {
  shadowsocks(name: 'shadowsocks'),
  shadowsocksr(name: 'shadowsocksr'),
  shadowtls(name: 'shadowtls'),
  vmess(name: 'vmess'),
  vless(name: 'vless'),
  trojan(name: 'trojan'),
  socks(name: 'socks'),
  http(name: 'http'),
  hysteria(name: 'hysteria'),
  hysteria2(name: 'hysteria2'),
  wireguard(name: 'wireguard'),
  tuic(name: 'tuic'),
  tor(name: 'tor'),
  ssh(name: 'ssh'),
  anytls(name: 'anytls'),
  naive(name: 'naive'),
  snell(name: 'snell'),
  tailscale(name: 'tailscale'),
  openvpn(name: 'openvpn-client'),
  mieru(name: 'mieru'),
  sudoku(name: 'sudoku'),
  trusttunnel(name: 'trusttunnel'),
  masque(name: 'masque');

  const SingboxOutboundType({required this.name});
  final String name;

  static List<String> getNames() {
    return [
      for (final value in SingboxOutboundType.values) value.name,
    ];
  }
}

class SingboxOutboundMultiplexBrutalOptions {
  bool? enabled;
  int? up_mbps;
  int? down_mbps;

  Map<String, dynamic> toJson() {
    final ret = <String, dynamic>{};
    if (enabled != null) {
      ret['enabled'] = enabled;
    }
    if (up_mbps != null) {
      ret['up_mbps'] = up_mbps;
    }
    if (down_mbps != null) {
      ret['down_mbps'] = down_mbps;
    }
    return ret;
  }

  void fromJson(Map<String, dynamic>? map) {
    if (map == null) {
      return;
    }
    enabled = map['enabled'];
    up_mbps = map['up_mbps'];
    down_mbps = map['down_mbps'];
  }

  Future<List<GroupItem>> getWidgetOptions(
    BuildContext context,
    SetStateCallback? setstate,
  ) async {
    final options = <GroupItemOptions>[
      GroupItemOptions(
        switchOptions: GroupItemSwitchOptions(
          name: 'enabled',
          switchValue: enabled,
          onSwitch: (bool value) async {
            enabled = value;
          },
        ),
      ),
      GroupItemOptions(
        textFormFieldOptions: GroupItemTextFieldOptions(
          name: 'up_mbps',
          keyboardType: TextInputType.number,
          text: up_mbps?.toString(),
          onChanged: (String value) {
            up_mbps = int.tryParse(value);
          },
        ),
      ),
      GroupItemOptions(
        textFormFieldOptions: GroupItemTextFieldOptions(
          name: 'down_mbps',
          keyboardType: TextInputType.number,
          text: down_mbps?.toString(),
          onChanged: (String value) {
            down_mbps = int.tryParse(value);
          },
        ),
      ),
    ];
    return [GroupItem(options: options)];
  }
}

typedef SingboxOutboundShadowsocksOptions = SingboxJsonOutboundShadowsocksOptions;
typedef SingboxOutboundShadowsocksROptions = SingboxJsonOutboundShadowsocksROptions;
typedef SingboxOutboundShadowTLSOptions = SingboxJsonOutboundShadowTLSOptions;
typedef SingboxOutboundVMessOptions = SingboxJsonOutboundVMessOptions;
typedef SingboxOutboundVLESSOptions = SingboxJsonOutboundVLESSOptions;
typedef SingboxOutboundTrojanOptions = SingboxJsonOutboundTrojanOptions;
typedef SingboxOutboundSocksOptions = SingboxJsonOutboundSocksOptions;
typedef SingboxOutboundHTTPOptions = SingboxJsonOutboundHTTPOptions;
typedef SingboxOutboundHysteriaOptions = SingboxJsonOutboundHysteriaOptions;
typedef SingboxOutboundHysteria2Options = SingboxJsonOutboundHysteria2Options;
typedef SingboxOutboundWireGuardOptions = SingboxJsonOutboundWireGuardOptions;
typedef SingboxOutboundTUICOptions = SingboxJsonOutboundTUICOptions;
typedef SingboxOutboundTorOptions = SingboxJsonOutboundTorOptions;
typedef SingboxOutboundSSHOptions = SingboxJsonOutboundSSHOptions;
typedef SingboxOutboundDialerOptions = SingboxJsonDialerOptions;

class SingboxOutboundOpenvpnOptions extends SingboxJsonServerOptions {
  String? username;
  String? password;
  String? security_strategy;
  String? tls_fragment;

  @override
  Map<String, dynamic> toJson() {
    final ret = super.toJson();
    if (username != null && username!.isNotEmpty) {
      ret['username'] = username;
    }
    if (password != null && password!.isNotEmpty) {
      ret['password'] = password;
    }
    if (security_strategy != null && security_strategy!.isNotEmpty) {
      ret['security_strategy'] = security_strategy;
    }
    return ret;
  }

  @override
  void fromJson(Map<String, dynamic>? map) {
    super.fromJson(map);
    if (map == null) {
      return;
    }
    username = map['username'];
    password = map['password'];
    security_strategy = map['security_strategy'];
  }

  Future<List<GroupItem>> getWidgetOptions(
    BuildContext context,
    SetStateCallback? setstate,
  ) async {
    final parentItems = await super.getWidgetOptions(context, setstate);
    final options = <GroupItemOptions>[
      GroupItemOptions(
        textFormFieldOptions: GroupItemTextFieldOptions(
          name: 'username',
          text: username,
          onChanged: (String value) {
            username = value;
          },
        ),
      ),
      GroupItemOptions(
        textFormFieldOptions: GroupItemTextFieldOptions(
          name: 'password',
          text: password,
          onChanged: (String value) {
            password = value;
          },
        ),
      ),
    ];
    return [...parentItems, GroupItem(options: options)];
  }
}

class SingboxOutboundMieruOptions extends SingboxJsonServerOptions {
  String? username;
  String? password;

  @override
  Map<String, dynamic> toJson() {
    final ret = super.toJson();
    if (username != null && username!.isNotEmpty) {
      ret['username'] = username;
    }
    if (password != null && password!.isNotEmpty) {
      ret['password'] = password;
    }
    return ret;
  }

  @override
  void fromJson(Map<String, dynamic>? map) {
    super.fromJson(map);
    if (map == null) {
      return;
    }
    username = map['username'];
    password = map['password'];
  }

  Future<List<GroupItem>> getWidgetOptions(
    BuildContext context,
    SetStateCallback? setstate,
  ) async {
    final parentItems = await super.getWidgetOptions(context, setstate);
    final options = <GroupItemOptions>[
      GroupItemOptions(
        textFormFieldOptions: GroupItemTextFieldOptions(
          name: 'username',
          text: username,
          onChanged: (String value) {
            username = value;
          },
        ),
      ),
      GroupItemOptions(
        textFormFieldOptions: GroupItemTextFieldOptions(
          name: 'password',
          text: password,
          onChanged: (String value) {
            password = value;
          },
        ),
      ),
    ];
    return [...parentItems, GroupItem(options: options)];
  }
}

class SingboxOutboundSudokuOptions extends SingboxJsonServerOptions {
  String? password;

  @override
  Map<String, dynamic> toJson() {
    final ret = super.toJson();
    if (password != null && password!.isNotEmpty) {
      ret['password'] = password;
    }
    return ret;
  }

  @override
  void fromJson(Map<String, dynamic>? map) {
    super.fromJson(map);
    if (map == null) {
      return;
    }
    password = map['password'];
  }

  Future<List<GroupItem>> getWidgetOptions(
    BuildContext context,
    SetStateCallback? setstate,
  ) async {
    final parentItems = await super.getWidgetOptions(context, setstate);
    final options = <GroupItemOptions>[
      GroupItemOptions(
        textFormFieldOptions: GroupItemTextFieldOptions(
          name: 'password',
          text: password,
          onChanged: (String value) {
            password = value;
          },
        ),
      ),
    ];
    return [...parentItems, GroupItem(options: options)];
  }
}

class SingboxOutboundTrustTunnelOptions extends SingboxJsonServerOptions {
  String? password;

  @override
  Map<String, dynamic> toJson() {
    final ret = super.toJson();
    if (password != null && password!.isNotEmpty) {
      ret['password'] = password;
    }
    return ret;
  }

  @override
  void fromJson(Map<String, dynamic>? map) {
    super.fromJson(map);
    if (map == null) {
      return;
    }
    password = map['password'];
  }

  Future<List<GroupItem>> getWidgetOptions(
    BuildContext context,
    SetStateCallback? setstate,
  ) async {
    final parentItems = await super.getWidgetOptions(context, setstate);
    final options = <GroupItemOptions>[
      GroupItemOptions(
        textFormFieldOptions: GroupItemTextFieldOptions(
          name: 'password',
          text: password,
          onChanged: (String value) {
            password = value;
          },
        ),
      ),
    ];
    return [...parentItems, GroupItem(options: options)];
  }
}

class SingboxOutboundMasqueOptions extends SingboxJsonServerOptions {}

class SingboxOutboundOptions {
  String type = '';
  String tag = '';
  String server = '';
  int server_port = 0;

  SingboxOutboundDialerOptions? dialer;
  SingboxOutboundShadowsocksOptions? shadowsocks;
  SingboxOutboundShadowsocksROptions? shadowsocksr;
  SingboxOutboundShadowTLSOptions? shadowtls;
  SingboxOutboundVMessOptions? vmess;
  SingboxOutboundVLESSOptions? vless;
  SingboxOutboundTrojanOptions? trojan;
  SingboxOutboundSocksOptions? socks;
  SingboxOutboundHTTPOptions? http;
  SingboxOutboundHysteriaOptions? hysteria;
  SingboxOutboundHysteria2Options? hysteria2;
  SingboxOutboundWireGuardOptions? wg;
  SingboxOutboundTUICOptions? tuic;
  SingboxOutboundTorOptions? tor;
  SingboxOutboundSSHOptions? ssh;
  SingboxOutboundAnyTlsOptions? anytls;
  SingboxOutboundNaiveOptions? naive;
  SingboxOutboundSnellOptions? snell;
  SingboxOutboundTailscaleOptions? tailscale;
  SingboxOutboundOpenvpnOptions? openvpn;
  SingboxOutboundMieruOptions? mieru;
  SingboxOutboundSudokuOptions? sudoku;
  SingboxOutboundTrustTunnelOptions? trusttunnel;
  SingboxOutboundMasqueOptions? masque;

  Map<String, dynamic> toJson() {
    final ret = <String, dynamic>{};
    if (dialer != null) {
      ret.addAll(dialer!.toJson());
    }
    final sub = switch (type) {
      'shadowsocks' => shadowsocks,
      'shadowsocksr' => shadowsocksr,
      'shadowtls' => shadowtls,
      'vmess' => vmess,
      'vless' => vless,
      'trojan' => trojan,
      'socks' => socks,
      'http' => http,
      'hysteria' => hysteria,
      'hysteria2' => hysteria2,
      'wireguard' => wg,
      'tuic' => tuic,
      'tor' => tor,
      'ssh' => ssh,
      'anytls' => anytls,
      'naive' => naive,
      'snell' => snell,
      'tailscale' => tailscale,
      'openvpn-client' => openvpn,
      'mieru' => mieru,
      'sudoku' => sudoku,
      'trusttunnel' => trusttunnel,
      'masque' => masque,
      _ => null,
    };
    if (sub != null) {
      ret.addAll(sub.toJson());
    }
    return ret;
  }

  void fromJson(Map<String, dynamic>? map) {
    if (map == null) {
      return;
    }
    type = map['type'] ?? '';
    tag = map['tag'] ?? '';
    server = map['server'] ?? '';
    server_port = map['server_port'] ?? 0;
    dialer = SingboxOutboundDialerOptions.fromJsonStatic(map);
    switch (type) {
      case 'shadowsocks':
        shadowsocks = SingboxJsonOutboundShadowsocksOptions.fromJsonStatic(map);
      case 'shadowsocksr':
        shadowsocksr =
            SingboxJsonOutboundShadowsocksROptions.fromJsonStatic(map);
      case 'shadowtls':
        shadowtls = SingboxJsonOutboundShadowTLSOptions.fromJsonStatic(map);
      case 'vmess':
        vmess = SingboxJsonOutboundVMessOptions.fromJsonStatic(map);
      case 'vless':
        vless = SingboxJsonOutboundVLESSOptions.fromJsonStatic(map);
      case 'trojan':
        trojan = SingboxJsonOutboundTrojanOptions.fromJsonStatic(map);
      case 'socks':
        socks = SingboxJsonOutboundSocksOptions.fromJsonStatic(map);
      case 'http':
        http = SingboxJsonOutboundHTTPOptions.fromJsonStatic(map);
      case 'hysteria':
        hysteria = SingboxJsonOutboundHysteriaOptions.fromJsonStatic(map);
      case 'hysteria2':
        hysteria2 = SingboxJsonOutboundHysteria2Options.fromJsonStatic(map);
      case 'wireguard':
        wg = SingboxJsonOutboundWireGuardOptions.fromJsonStatic(map);
      case 'tuic':
        tuic = SingboxJsonOutboundTUICOptions.fromJsonStatic(map);
      case 'tor':
        tor = SingboxJsonOutboundTorOptions.fromJsonStatic(map);
      case 'ssh':
        ssh = SingboxJsonOutboundSSHOptions.fromJsonStatic(map);
      case 'anytls':
        anytls = SingboxOutboundAnyTlsOptions()..fromJson(map);
      case 'naive':
        naive = SingboxOutboundNaiveOptions()..fromJson(map);
      case 'snell':
        snell = SingboxOutboundSnellOptions()..fromJson(map);
      case 'tailscale':
        tailscale = SingboxOutboundTailscaleOptions()..fromJson(map);
      case 'openvpn-client':
        openvpn = SingboxOutboundOpenvpnOptions()..fromJson(map);
      case 'mieru':
        mieru = SingboxOutboundMieruOptions()..fromJson(map);
      case 'sudoku':
        sudoku = SingboxOutboundSudokuOptions()..fromJson(map);
      case 'trusttunnel':
        trusttunnel = SingboxOutboundTrustTunnelOptions()..fromJson(map);
      case 'masque':
        masque = SingboxOutboundMasqueOptions()..fromJson(map);
    }
  }

  bool isValid() {
    switch (type) {
      case 'shadowsocks':
      case 'shadowsocksr':
      case 'shadowtls':
      case 'vmess':
      case 'vless':
      case 'trojan':
      case 'socks':
      case 'http':
      case 'hysteria':
      case 'hysteria2':
      case 'wireguard':
      case 'tuic':
      case 'tor':
      case 'ssh':
      case 'anytls':
      case 'naive':
      case 'snell':
      case 'tailscale':
      case 'openvpn-client':
      case 'mieru':
      case 'sudoku':
      case 'trusttunnel':
      case 'masque':
        return true;
    }
    return false;
  }

  Future<List<GroupItem>> getWidgetOptions(
    BuildContext context,
    SetStateCallback? setstate,
  ) async {
    final sub = switch (type) {
      'shadowsocks' => shadowsocks,
      'shadowsocksr' => shadowsocksr,
      'shadowtls' => shadowtls,
      'vmess' => vmess,
      'vless' => vless,
      'trojan' => trojan,
      'socks' => socks,
      'http' => http,
      'hysteria' => hysteria,
      'hysteria2' => hysteria2,
      'wireguard' => wg,
      'tuic' => tuic,
      'tor' => tor,
      'ssh' => ssh,
      'anytls' => anytls,
      'naive' => naive,
      'snell' => snell,
      'tailscale' => tailscale,
      'openvpn-client' => openvpn,
      'mieru' => mieru,
      'sudoku' => sudoku,
      'trusttunnel' => trusttunnel,
      _ => null,
    };
    if (sub is SingboxJsonServerOptions) {
      return sub.getWidgetOptions(context, setstate);
    }
    return [];
  }
}

class SingboxOutboundAnyTlsOptions extends SingboxJsonServerOptions {
  String? password;
  @override Map<String, dynamic> toJson() {
    final ret = super.toJson();
    if (password != null && password!.isNotEmpty) ret['password'] = password;
    return ret;
  }
  @override void fromJson(Map<String, dynamic>? map) {
    super.fromJson(map);
    if (map != null) password = map['password'];
  }
}
class SingboxOutboundNaiveOptions extends SingboxJsonServerOptions {
  String? username;
  String? password;
  @override Map<String, dynamic> toJson() {
    final ret = super.toJson();
    if (username != null && username!.isNotEmpty) ret['username'] = username;
    if (password != null && password!.isNotEmpty) ret['password'] = password;
    return ret;
  }
  @override void fromJson(Map<String, dynamic>? map) {
    super.fromJson(map);
    if (map != null) { username = map['username']; password = map['password']; }
  }
}
class SingboxOutboundSnellOptions extends SingboxJsonServerOptions {
  int? version;
  String? password;
  @override Map<String, dynamic> toJson() {
    final ret = super.toJson();
    if (version != null) ret['version'] = version;
    if (password != null && password!.isNotEmpty) ret['password'] = password;
    return ret;
  }
  @override void fromJson(Map<String, dynamic>? map) {
    super.fromJson(map);
    if (map != null) { version = map['version']; password = map['password']; }
  }
}
class SingboxOutboundTailscaleOptions extends SingboxJsonServerOptions {
  String? auth_key;
  @override Map<String, dynamic> toJson() {
    final ret = super.toJson();
    if (auth_key != null && auth_key!.isNotEmpty) ret['auth_key'] = auth_key;
    return ret;
  }
  @override void fromJson(Map<String, dynamic>? map) {
    super.fromJson(map);
    if (map != null) auth_key = map['auth_key'];
  }
}
