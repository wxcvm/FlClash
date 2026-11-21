// ignore_for_file: non_constant_identifier_names

class VpnServiceConfig {
  int control_port = 0;
  String base_dir = '';
  String work_dir = '';
  String cache_dir = '';
  String core_path = '';
  String log_path = '';
  String err_path = '';
  String id = '';
  String version = '';
  String name = '';
  String secret = '';
  String install_refer = '';
  int expired_time = 0;
  String time_connect = '';
  String time_disconnect = '';
  String sentry_minversion = '';

  Map<String, Object> toJson() => {
    'control_port': control_port,
    'base_dir': base_dir,
    'work_dir': work_dir,
    'cache_dir': cache_dir,
    'core_path': core_path,
    'log_path': log_path,
    'err_path': err_path,
    'id': id,
    'version': version,
    'name': name,
    'secret': secret,
    'install_refer': install_refer,
    'expired_time': expired_time,
    'time_connect': time_connect,
    'time_disconnect': time_disconnect,
    'sentry_minversion': sentry_minversion,
  };

  void fromJson(Map<String, dynamic> json) {
    control_port = json['control_port'] as int? ?? control_port;
    base_dir = json['base_dir'] as String? ?? base_dir;
    work_dir = json['work_dir'] as String? ?? work_dir;
    cache_dir = json['cache_dir'] as String? ?? cache_dir;
    core_path = json['core_path'] as String? ?? core_path;
    log_path = json['log_path'] as String? ?? log_path;
    err_path = json['err_path'] as String? ?? err_path;
    id = json['id'] as String? ?? id;
    version = json['version'] as String? ?? version;
    name = json['name'] as String? ?? name;
    secret = json['secret'] as String? ?? secret;
    install_refer = json['install_refer'] as String? ?? install_refer;
    expired_time = json['expired_time'] as int? ?? expired_time;
    time_connect = json['time_connect'] as String? ?? time_connect;
    time_disconnect = json['time_disconnect'] as String? ?? time_disconnect;
    sentry_minversion = json['sentry_minversion'] as String? ?? sentry_minversion;
  }
}
