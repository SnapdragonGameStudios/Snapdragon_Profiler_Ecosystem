//============================================================================================================
//  
//                   Copyright (c) 2023, Qualcomm Innovation Center, Inc. All rights reserved.
//                               SPDX-License-Identifier: BSD-3-Clause
//  
//============================================================================================================ 

package com.sdp.tunnel;

import java.util.ArrayList;
import java.util.List;
import java.util.logging.ConsoleHandler;
import java.util.logging.Level;
import java.util.logging.Logger;
import java.util.logging.SimpleFormatter;

/**
 * Reverse WebSocket tunnel – Windows side.
 * <p>
 * Java equivalent of {@code tunnel_windows_reverse.py}.
 * Connects to the Linux/Android WebSocket server and forwards to local ports
 * where SDPCore is listening.
 * <p>
 * Usage:
 * <pre>
 *   # Single port
 *   java -cp sdp-tunnel.jar com.sdp.tunnel.TunnelWindowsReverse --remote-host 192.168.1.100
 *
 *   # Multiple ports
 *   java -cp sdp-tunnel.jar com.sdp.tunnel.TunnelWindowsReverse \
 *       --remote-host peixa-gv --port-map 9000:6500 --port-map 9002:6502
 * </pre>
 */
public class TunnelWindowsReverse {

    private static final Logger LOG = Logger.getLogger(TunnelWindowsReverse.class.getName());

    public static void main(String[] args) {
        String remoteHost = null;
        Integer remotePort = null;
        String forwardHost = "127.0.0.1";
        Integer forwardPort = null;
        boolean noReconnect = false;
        boolean verbose = false;
        List<int[]> portMaps = new ArrayList<>();

        for (int i = 0; i < args.length; i++) {
            switch (args[i]) {
                case "--remote-host":
                    remoteHost = args[++i];
                    break;
                case "--remote-port":
                    remotePort = Integer.parseInt(args[++i]);
                    break;
                case "--forward-host":
                    forwardHost = args[++i];
                    break;
                case "--forward-port":
                    forwardPort = Integer.parseInt(args[++i]);
                    break;
                case "--port-map":
                    String[] parts = args[++i].split(":");
                    if (parts.length != 2) {
                        System.err.println("Invalid --port-map format. Expected WS_PORT:FORWARD_PORT (e.g. 9000:6500)");
                        System.exit(1);
                    }
                    portMaps.add(new int[]{Integer.parseInt(parts[0]), Integer.parseInt(parts[1])});
                    break;
                case "--no-reconnect":
                    noReconnect = true;
                    break;
                case "-v":
                case "--verbose":
                    verbose = true;
                    break;
                case "-h":
                case "--help":
                    printUsage();
                    return;
                default:
                    System.err.println("Unknown argument: " + args[i]);
                    printUsage();
                    System.exit(1);
            }
        }

        if (remoteHost == null) {
            System.err.println("ERROR: --remote-host is required");
            printUsage();
            System.exit(1);
        }

        configureLogging(verbose);
        boolean doReconnect = !noReconnect;

        List<WindowsTunnelPort> tunnels = new ArrayList<>();
        if (!portMaps.isEmpty()) {
            for (int[] pm : portMaps) {
                tunnels.add(new WindowsTunnelPort(
                        "ws://" + remoteHost + ":" + pm[0],
                        forwardHost, pm[1], doReconnect));
            }
        } else {
            int rp = (remotePort != null) ? remotePort : 9000;
            int fp = (forwardPort != null) ? forwardPort : 6500;
            tunnels.add(new WindowsTunnelPort(
                    "ws://" + remoteHost + ":" + rp,
                    forwardHost, fp, doReconnect));
        }

        LOG.info(String.format("Starting %d tunnel(s)", tunnels.size()));
        for (WindowsTunnelPort t : tunnels) {
            LOG.info(String.format("  %s → %s:%d", t.getRemoteWsUrl(), t.getForwardHost(), t.getForwardPort()));
        }

        final List<WindowsTunnelPort> finalTunnels = tunnels;
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            LOG.info("Shutdown signal received – stopping tunnels");
            for (WindowsTunnelPort t : finalTunnels) {
                t.stop();
            }
        }));

        List<Thread> threads = new ArrayList<>();
        for (WindowsTunnelPort tunnel : tunnels) {
            Thread thread = new Thread(() -> {
                try {
                    tunnel.run();
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                } catch (Exception e) {
                    LOG.log(Level.SEVERE, "Tunnel failed: " + e.getMessage(), e);
                }
            });
            thread.setDaemon(false);
            thread.start();
            threads.add(thread);
        }

        for (Thread thread : threads) {
            try {
                thread.join();
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                break;
            }
        }

        LOG.info("All reverse tunnels (Windows side) stopped");
    }

    private static void configureLogging(boolean verbose) {
        Logger rootLogger = Logger.getLogger("com.sdp.tunnel");
        rootLogger.setLevel(verbose ? Level.ALL : Level.INFO);

        Logger globalRoot = Logger.getLogger("");
        for (var h : globalRoot.getHandlers()) {
            globalRoot.removeHandler(h);
        }

        ConsoleHandler handler = new ConsoleHandler();
        handler.setLevel(verbose ? Level.ALL : Level.INFO);
        handler.setFormatter(new SimpleFormatter());
        globalRoot.addHandler(handler);
    }

    private static void printUsage() {
        System.out.println(
            "Reverse WebSocket tunnel – Windows side.\n" +
            "Connects to Linux/Android WS and forwards to local ports.\n\n" +
            "Usage:\n" +
            "  java -cp sdp-tunnel.jar com.sdp.tunnel.TunnelWindowsReverse [options]\n\n" +
            "Options:\n" +
            "  --remote-host HOST        Linux/Android host (required)\n" +
            "  --remote-port PORT        Linux WS port (default: 9000)\n" +
            "  --forward-host HOST       Local host to forward to (default: 127.0.0.1)\n" +
            "  --forward-port PORT       Local port to forward to (default: 6500)\n" +
            "  --port-map WS:FWD         Port mapping (repeatable)\n" +
            "  --no-reconnect            Disable auto-reconnection\n" +
            "  -v, --verbose             Enable debug logging\n" +
            "  -h, --help                Show this help\n\n" +
            "Examples:\n" +
            "  # Single port\n" +
            "  java -cp sdp-tunnel.jar com.sdp.tunnel.TunnelWindowsReverse \\\n" +
            "      --remote-host 192.168.1.100\n\n" +
            "  # Multiple ports\n" +
            "  java -cp sdp-tunnel.jar com.sdp.tunnel.TunnelWindowsReverse \\\n" +
            "      --remote-host peixa-gv --port-map 9000:6500 --port-map 9002:6502\n\n" +
            "Startup order:\n" +
            "  1. Start SDPCore on Windows (binds to :6500, :6502, etc.)\n" +
            "  2. Start TunnelLinuxReverse on Linux/Android\n" +
            "  3. Start this on Windows"
        );
    }
}