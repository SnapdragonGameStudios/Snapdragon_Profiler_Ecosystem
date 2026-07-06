//============================================================================================================
//  
//                   Copyright (c) 2023, Qualcomm Innovation Center, Inc. All rights reserved.
//                               SPDX-License-Identifier: BSD-3-Clause
//  
//============================================================================================================ 

package com.sdp.tunnel;

import org.java_websocket.client.WebSocketClient;
import org.java_websocket.handshake.ServerHandshake;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.Socket;
import java.net.URI;
import java.nio.ByteBuffer;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.logging.Level;
import java.util.logging.Logger;

/**
 * One independent tunnel: WebSocket client + TCP forwarder.
 * <p>
 * Equivalent to the Python {@code TunnelPort} class in {@code tunnel_windows_reverse.py}.
 * Connects to the Linux/Android WebSocket server and, for each CONNECT message,
 * opens a TCP connection to the local forward port (where SDPCore listens).
 */
public class WindowsTunnelPort {

    private static final Logger LOG = Logger.getLogger(WindowsTunnelPort.class.getName());
    private static final int BUFFER_SIZE = 65536;
    private static final int RECONNECT_DELAY_MS = 3000;

    private final String remoteWsUrl;
    private final String forwardHost;
    private final int forwardPort;
    private final boolean reconnect;
    private final String label;

    private volatile WebSocketClient wsClient = null;

    /** Active TCP connections to SDPCore, keyed by UUID hex. */
    private final ConcurrentHashMap<String, Socket> tcpConnections = new ConcurrentHashMap<>();

    private final ExecutorService executor = Executors.newCachedThreadPool(r -> {
        Thread t = new Thread(r);
        t.setDaemon(true);
        return t;
    });

    private final AtomicBoolean running = new AtomicBoolean(true);

    public WindowsTunnelPort(String remoteWsUrl, String forwardHost, int forwardPort, boolean reconnect) {
        this.remoteWsUrl = remoteWsUrl;
        this.forwardHost = forwardHost;
        this.forwardPort = forwardPort;
        this.reconnect = reconnect;
        this.label = "ws→" + remoteWsUrl + "→fwd:" + forwardPort;
    }

    public String getRemoteWsUrl() { return remoteWsUrl; }
    public String getForwardHost() { return forwardHost; }
    public int getForwardPort() { return forwardPort; }

    // ── TCP reader loop ─────────────────────────────────────────────────

    private void tcpReaderLoop(byte[] connIdBytes, String connHex, Socket socket) {
        String shortId = connHex.substring(0, 8);
        try {
            InputStream in = socket.getInputStream();
            byte[] buf = new byte[BUFFER_SIZE];
            int n;
            while (running.get() && (n = in.read(buf)) != -1) {
                WebSocketClient ws = this.wsClient;
                if (ws != null && ws.isOpen()) {
                    byte[] frame = new byte[16 + n];
                    System.arraycopy(connIdBytes, 0, frame, 0, 16);
                    System.arraycopy(buf, 0, frame, 16, n);
                    try {
                        ws.send(frame);
                    } catch (Exception e) {
                        LOG.warning(String.format("[%s][%s] WS send failed: %s", label, shortId, e.getMessage()));
                        break;
                    }
                } else {
                    break;
                }
            }
        } catch (IOException e) {
            LOG.log(Level.FINE, "[{0}][{1}] TCP read stopped: {2}", new Object[]{label, shortId, e.getMessage()});
        } finally {
            Socket removed = tcpConnections.remove(connHex);
            if (removed != null) closeQuietly(removed);
            // Notify Linux side
            WebSocketClient ws = this.wsClient;
            if (ws != null && ws.isOpen()) {
                try { ws.send("DISCONNECT:" + connHex); } catch (Exception ignored) {}
            }
            LOG.info(String.format("[%s][%s] TCP connection to SDPCore closed", label, shortId));
        }
    }

    // ── Message handlers ────────────────────────────────────────────────

    private void handleConnect(String connHex) {
        byte[] connIdBytes = UuidUtil.fromHex(connHex);
        String shortId = connHex.substring(0, 8);
        LOG.info(String.format("[%s][%s] Opening TCP connection to %s:%d", label, shortId, forwardHost, forwardPort));

        try {
            Socket socket = new Socket(forwardHost, forwardPort);
            tcpConnections.put(connHex, socket);
            executor.submit(() -> tcpReaderLoop(connIdBytes, connHex, socket));
            LOG.info(String.format("[%s][%s] TCP connection established", label, shortId));
        } catch (IOException e) {
            LOG.severe(String.format("[%s][%s] Cannot connect to %s:%d – %s", label, shortId, forwardHost, forwardPort, e.getMessage()));
            WebSocketClient ws = this.wsClient;
            if (ws != null && ws.isOpen()) {
                try { ws.send("DISCONNECT:" + connHex); } catch (Exception ignored) {}
            }
        }
    }

    private void handleDisconnect(String connHex) {
        Socket sock = tcpConnections.remove(connHex);
        if (sock != null) {
            closeQuietly(sock);
            LOG.info(String.format("[%s][%s] TCP connection closed by Linux side", label, connHex.substring(0, 8)));
        }
    }

    private void handleData(ByteBuffer buf) {
        if (buf.remaining() <= 16) return;

        byte[] connIdBytes = new byte[16];
        buf.get(connIdBytes);
        String connHex = UuidUtil.toHex(connIdBytes);

        byte[] payload = new byte[buf.remaining()];
        buf.get(payload);

        Socket sock = tcpConnections.get(connHex);
        if (sock != null) {
            try {
                OutputStream out = sock.getOutputStream();
                out.write(payload);
                out.flush();
            } catch (IOException e) {
                LOG.log(Level.FINE, "[{0}][{1}] TCP write failed: {2}",
                        new Object[]{label, connHex.substring(0, 8), e.getMessage()});
            }
        } else {
            LOG.fine(String.format("[%s] Data for unknown connection %s", label, connHex.substring(0, 8)));
        }
    }

    // ── Clean up ────────────────────────────────────────────────────────

    private void dropAllTcpConnections() {
        for (String key : tcpConnections.keySet()) {
            Socket s = tcpConnections.remove(key);
            if (s != null) closeQuietly(s);
        }
        LOG.info(String.format("[%s] All TCP connections dropped (tunnel down)", label));
    }

    // ── WebSocket loop ──────────────────────────────────────────────────

    private void wsLoop() throws InterruptedException {
        LOG.info(String.format("[%s] Connecting to %s …", label, remoteWsUrl));

        final Object closeLatch = new Object();

        WebSocketClient client = new WebSocketClient(URI.create(remoteWsUrl)) {
            @Override
            public void onOpen(ServerHandshake handshake) {
                LOG.info(String.format("[%s] WebSocket connected to %s", label, remoteWsUrl));
            }

            @Override
            public void onMessage(String message) {
                if (message.startsWith("CONNECT:")) {
                    String connHex = message.substring("CONNECT:".length());
                    handleConnect(connHex);
                } else if (message.startsWith("DISCONNECT:")) {
                    String connHex = message.substring("DISCONNECT:".length());
                    handleDisconnect(connHex);
                } else {
                    LOG.fine(String.format("[%s] Unknown text message: %s", label,
                            message.length() > 60 ? message.substring(0, 60) : message));
                }
            }

            @Override
            public void onMessage(ByteBuffer buf) {
                handleData(buf);
            }

            @Override
            public void onClose(int code, String reason, boolean remote) {
                LOG.info(String.format("[%s] WebSocket closed (code=%d, reason=%s, remote=%b)", label, code, reason, remote));
                synchronized (closeLatch) {
                    closeLatch.notifyAll();
                }
            }

            @Override
            public void onError(Exception ex) {
                LOG.log(Level.WARNING, "[" + label + "] WebSocket error: " + ex.getMessage(), ex);
                synchronized (closeLatch) {
                    closeLatch.notifyAll();
                }
            }
        };

        this.wsClient = client;

        try {
            client.connectBlocking();
        } catch (InterruptedException e) {
            throw e;
        }

        // Wait until connection closes
        synchronized (closeLatch) {
            while (client.isOpen()) {
                closeLatch.wait(1000);
            }
        }

        this.wsClient = null;
        dropAllTcpConnections();
    }

    // ── Run ─────────────────────────────────────────────────────────────

    /**
     * Main loop with optional auto-reconnection. Blocks until stopped.
     */
    public void run() throws InterruptedException {
        while (running.get()) {
            try {
                wsLoop();
            } catch (InterruptedException e) {
                throw e;
            } catch (Exception e) {
                LOG.warning(String.format("[%s] Connection failed: %s", label, e.getMessage()));
            }

            if (!reconnect || !running.get()) break;

            LOG.info(String.format("[%s] Reconnecting in %d seconds …", label, RECONNECT_DELAY_MS / 1000));
            Thread.sleep(RECONNECT_DELAY_MS);
        }
        executor.shutdownNow();
    }

    /** Signal this tunnel to stop. */
    public void stop() {
        running.set(false);
        WebSocketClient ws = this.wsClient;
        if (ws != null) {
            try { ws.close(); } catch (Exception ignored) {}
        }
    }

    private static void closeQuietly(Socket s) {
        try { s.close(); } catch (IOException ignored) {}
    }
}