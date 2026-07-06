//============================================================================================================
//  
//                   Copyright (c) 2023, Qualcomm Innovation Center, Inc. All rights reserved.
//                               SPDX-License-Identifier: BSD-3-Clause
//  
//============================================================================================================ 

package com.sdp.tunnel;

import java.io.IOException;
import java.util.ArrayList;
import java.util.List;
import java.util.logging.ConsoleHandler;
import java.util.logging.Level;
import java.util.logging.Logger;
import java.util.logging.SimpleFormatter;

/**
 * Reverse WebSocket tunnel – Android side.
 * <p>
 * Simulates {@code ssh -R 6500:127.0.0.1:6500} using WebSocket.
 * <p>
 * This is the Java equivalent of {@code tunnel_linux_reverse.py} and is
 * designed to run on Android (or any JVM environment).
 * <p>
 * Usage:
 * <pre>
 *   # Single port (backward compatible)
 *   java -jar sdp-tunnel.jar --tcp-port 6500 --ws-port 9000
 *
 *   # Multiple ports
 *   java -jar sdp-tunnel.jar --port-map 6500:9000 --port-map 6502:9002
 * </pre>
 */
public class TunnelAndroidReverse {

    private static final Logger LOG = Logger.getLogger(TunnelAndroidReverse.class.getName());

    public static void main(String[] args) {
        // Defaults
        String tcpHost = "0.0.0.0";
        String wsHost = "0.0.0.0";
        Integer tcpPort = null;
        Integer wsPort = null;
        boolean verbose = false;
        List<int[]> portMaps = new ArrayList<>();

        // Simple argument parsing
        for (int i = 0; i < args.length; i++) {
            switch (args[i]) {
                case "--tcp-host":
                    tcpHost = args[++i];
                    break;
                case "--tcp-port":
                    tcpPort = Integer.parseInt(args[++i]);
                    break;
                case "--ws-host":
                    wsHost = args[++i];
                    break;
                case "--ws-port":
                    wsPort = Integer.parseInt(args[++i]);
                    break;
                case "--port-map":
                    String[] parts = args[++i].split(":");
                    if (parts.length != 2) {
                        System.err.println("Invalid --port-map format. Expected TCP_PORT:WS_PORT (e.g. 6500:9000)");
                        System.exit(1);
                    }
                    portMaps.add(new int[]{Integer.parseInt(parts[0]), Integer.parseInt(parts[1])});
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

        // Configure logging
        configureLogging(verbose);

        // Build tunnel list
        List<AndroidTunnelPort> tunnels = new ArrayList<>();
        if (!portMaps.isEmpty()) {
            for (int[] pm : portMaps) {
                tunnels.add(new AndroidTunnelPort(tcpHost, pm[0], wsHost, pm[1]));
            }
        } else {
            // Backward-compatible single-port mode
            int tp = (tcpPort != null) ? tcpPort : 6500;
            int wp = (wsPort != null) ? wsPort : 9000;
            tunnels.add(new AndroidTunnelPort(tcpHost, tp, wsHost, wp));
        }

        LOG.info(String.format("Starting %d tunnel(s)", tunnels.size()));
        for (AndroidTunnelPort t : tunnels) {
            LOG.info(String.format("  TCP %s ↔ WS", t));
        }

        // Register shutdown hook for clean stop
        final List<AndroidTunnelPort> finalTunnels = tunnels;
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            LOG.info("Shutdown signal received – stopping tunnels");
            for (AndroidTunnelPort t : finalTunnels) {
                t.stop();
            }
        }));

        // Start each tunnel in its own thread
        List<Thread> threads = new ArrayList<>();
        for (AndroidTunnelPort tunnel : tunnels) {
            Thread thread = new Thread(() -> {
                try {
                    tunnel.start();
                } catch (IOException | InterruptedException e) {
                    LOG.log(Level.SEVERE, "Tunnel failed: " + e.getMessage(), e);
                }
            });
            thread.setDaemon(false);
            thread.start();
            threads.add(thread);
        }

        // Wait for all tunnel threads
        for (Thread thread : threads) {
            try {
                thread.join();
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                break;
            }
        }

        LOG.info("All reverse tunnels (Android side) stopped");
    }

    private static void configureLogging(boolean verbose) {
        Logger rootLogger = Logger.getLogger("com.sdp.tunnel");
        rootLogger.setLevel(verbose ? Level.ALL : Level.INFO);

        // Remove default handlers
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
            "Reverse WebSocket tunnel – Android side.\n" +
            "Simulates ssh -R via WebSocket. Supports multiple port mappings.\n\n" +
            "Usage:\n" +
            "  java -jar sdp-tunnel.jar [options]\n\n" +
            "Options:\n" +
            "  --tcp-host HOST       TCP listen host (default: 0.0.0.0)\n" +
            "  --tcp-port PORT       TCP listen port (default: 6500)\n" +
            "  --ws-host HOST        WebSocket listen host (default: 0.0.0.0)\n" +
            "  --ws-port PORT        WebSocket listen port (default: 9000)\n" +
            "  --port-map TCP:WS     Port mapping (repeatable)\n" +
            "  -v, --verbose         Enable debug logging\n" +
            "  -h, --help            Show this help\n\n" +
            "Examples:\n" +
            "  # Single port\n" +
            "  java -jar sdp-tunnel.jar --tcp-port 6500 --ws-port 9000\n\n" +
            "  # Multiple ports\n" +
            "  java -jar sdp-tunnel.jar --port-map 6500:9000 --port-map 6502:9002\n\n" +
            "Startup order:\n" +
            "  1. Start SDPCore on Windows (binds to :6500, :6502, etc.)\n" +
            "  2. Start this on Android\n" +
            "  3. Start tunnel_windows_reverse on Windows"
        );
    }
}