import io.nekohasekai.libbox.CommandServer;
import io.nekohasekai.libbox.CommandServerHandler;
import io.nekohasekai.libbox.Libbox;
import io.nekohasekai.libbox.OverrideOptions;
import io.nekohasekai.libbox.PlatformInterface;

// Compile-only contract for the pinned upstream gomobile API.
// Do not load either JNI runtime in this host-side probe.
final class LibboxApiProbe {
    static void validate(String config) throws Exception {
        Libbox.checkConfig(config);
        if (!Libbox.hasTunInbound(config)) {
            throw new IllegalArgumentException("Android VPN requires a TUN inbound");
        }
    }

    static CommandServer start(
            String config,
            CommandServerHandler handler,
            PlatformInterface platform
    ) throws Exception {
        validate(config);
        CommandServer server = Libbox.newCommandServer(handler, platform);
        try {
            server.start();
            server.startOrReloadService(config, new OverrideOptions());
            return server;
        } catch (Exception error) {
            server.close();
            throw error;
        }
    }

    static void reset(CommandServer server) {
        server.resetNetwork();
    }

    static void stop(CommandServer server) throws Exception {
        try {
            server.closeService();
        } finally {
            server.close();
        }
    }
}
