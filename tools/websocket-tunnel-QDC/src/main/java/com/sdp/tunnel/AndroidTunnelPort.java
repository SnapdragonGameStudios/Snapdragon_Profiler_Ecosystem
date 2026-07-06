//============================================================================================================
//  
//                   Copyright (c) 2023, Qualcomm Innovation Center, Inc. All rights reserved.
//                               SPDX-License-Identifier: BSD-3-Clause
//  
//============================================================================================================ 


package com.sdp.tunnel;

import org.java_websocket.WebSocket;
import org.java_websocket.handshake.ClientHandshake;
import org.java_websocket.server.WebSocketServer;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.ByteBuffer;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.logging.Level;
import java.util.logging.Logger;

/**
 * One independent tunnel: TCP listener + WebSocket server.
 * <p>
 * Equivalent to the Python {@code TunnelPort} class in {@code tunnel_linux_reverse.py}.
 * <p>
 * Protocol:
 * <ul>
 *   <li>Text: {@code CONNECT:<uuid_hex>} — new TCP client connected</li>
 *   <li>Text: {@code DISCONNECT:<uuid_hex>} — TCP client disconnected</li>
 *   <li>Binary: first 16 bytes = UUID, rest = payload</li>
 * </ul>
 */
public class AndroidTunnelPort {

    private static final Logger LOG = Logger.getLogger(AndroidTunnelPort.class.getName());
    private static final int BUFFER_SIZE = 65536;

    private final String tcpHost;
    private final int tcpPort;
    private final String wsHost;
    private final int wsPort;
    private final String label;

    /** Active TCP client sockets, keyed by 16-byte UUID. */
    private final ConcurrentHashMap<String, Socket> tcpClients = new ConcurrentHashMap<>();

    /** The single WebSocket connection from the Windows tunnel client (if any). */
    private volatile WebSocket wsConn = null;

    /** Thread pool for TCP reader loops. */
    private final ExecutorService executor = Executors.newCachedThreadPool(r -> {
        Thread t = new Thread(r);
        t.setDaemon(true);
        return t;
    });

    private final AtomicBoolean running = new AtomicBoolean(true);

    public AndroidTunnelPort(String tcpHost, int tcpPort, String wsHost, int wsPort) {
        this.tcpHost = tcpHost;
        this.tcpPort = tcpPort;
        this.wsHost = wsHost;
        this.wsPort = wsPort;
        this.label = "tcp:" + tcpPort + "↔ws:" + wsPort;
    }

    // ── Helpers ──────────────────────────────────────────────────────────

    private void sendWsText(String text) {
        WebSocket ws = this.wsConn;
        if (ws != null && ws.isOpen()) {
            try {
                ws.send(text);
            } catch (Exception e) {
                LOG.log(Level.WARNING, "[{0}] WS text send failed: {1}", new Object[]{label, e.getMessage()});
            }
        }
    }

    private void sendWsBinary(byte[] data) {
        WebSocket ws = this.wsConn;
        if (ws != null && ws.isOpen()) {
            try {
                ws.send(data);
            } catch (Exception e) {
                LOG.log(Level.WARNING, "[{0}] WS binary send failed: {1}", new Object[]{label, e.getMessage()});
            }
        }
    }

    // ── TCP listener ────────────────────────────────────────────────────

    private void handleTcpClient(Socket clientSocket) {
        byte[] connIdBytes = UuidUtil.randomBytes();
        String connHex = UuidUtil.toHex(connIdBytes);
        String shortId = connHex.substring(0, 8);

        LOG.info(String.format("[%s][%s] TCP client connected from %s", label, shortId, clientSocket.getRemoteSocketAddress()));
        tcpClients.put(connHex, clientSocket);

        // Notify Windows side
        sendWsText("CONNECT:" + connHex);

        try {
            InputStream in = clientSocket.getInputStream();
            byte[] buf = new byte[BUFFER_SIZE];
            int n;
            while (running.get() && (n = in.read(buf)) != -1) {
                // Binary frame: 16-byte UUID + payload
                byte[] frame = new byte[16 + n];
                System.arraycopy(connIdBytes, 0, frame, 0, 16);
                System.arraycopy(buf, 0, frame, 16, n);
                sendWsBinary(frame);
            }
        } catch (IOException e) {
            LOG.log(Level.FINE, "[{0}][{1}] TCP read stopped: {2}", new Object[]{label, shortId, e.getMessage()});
        } finally {
            tcpClients.remove(connHex);
            sendWsText("DISCONNECT:" + connHex);
            closeQuietly(clientSocket);
            LOG.info(String.format("[%s][%s] TCP client disconnected", label, shortId));
        }
    }

    // ── WebSocket server ────────────────────────────────────────────────

    private WebSocketServer createWsServer() {
        InetSocketAddress addr = new InetSocketAddress(wsHost, wsPort);
        return new WebSocketServer(addr) {
            @Override
            public void onOpen(WebSocket conn, ClientHandshake handshake) {
                LOG.info(String.format("[%s] Windows tunnel client connected from %s", label, conn.getRemoteSocketAddress()));
                WebSocket old = wsConn;
                if (old != null && old.isOpen()) {
                    LOG.warning(String.format("[%s] Replacing existing WebSocket connection", label));
                    try { old.close(); } catch (Exception ignored) {}
                }
                wsConn = conn;
            }

            @Override
            public void onClose(WebSocket conn, int code, String reason, boolean remote) {
                LOG.info(String.format("[%s] Windows tunnel client disconnected (code=%d, reason=%s)", label, code, reason));
                if (wsConn == conn) {
                    wsConn = null;
                }
                // Drop all TCP clients since tunnel is down
                dropAllTcpClients();
            }

            @Override
            public void onMessage(WebSocket conn, String message) {
                // Text control message from Windows side
                if (message.startsWith("DISCONNECT:")) {
                    String connHex = message.substring("DISCONNECT:".length());
                    Socket sock = tcpClients.remove(connHex);
                    if (sock != null) {
                        closeQuietly(sock);
                        LOG.info(String.format("[%s][%s] TCP client closed by Windows side", label, connHex.substring(0, 8)));
                    }
                } else {
                    LOG.fine(String.format("[%s] Unknown text message: %s", label, message.length() > 60 ? message.substring(0, 60) : message));
                }
            }

            @Override
            public void onMessage(WebSocket conn, ByteBuffer buf) {
                // Binary frame: first 16 bytes = UUID, rest = payload
                if (buf.remaining() <= 16) return;

                byte[] connIdBytes = new byte[16];
                buf.get(connIdBytes);
                String connHex = UuidUtil.toHex(connIdBytes);

                byte[] payload = new byte[buf.remaining()];
                buf.get(payload);

                Socket sock = tcpClients.get(connHex);
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

            @Override
            public void onError(WebSocket conn, Exception ex) {
                LOG.log(Level.WARNING, "[" + label + "] WebSocket error: " + ex.getMessage(), ex);
            }

            @Override
            public void onStart() {
                LOG.info(String.format("[%s] WebSocket server started on ws://%s:%d", label, wsHost, wsPort));
            }
        };
    }

    // ── Lifecycle ───────────────────────────────────────────────────────

    private void dropAllTcpClients() {
        for (String key : tcpClients.keySet()) {
            Socket s = tcpClients.remove(key);
            if (s != null) closeQuietly(s);
        }
        LOG.info(String.format("[%s] All TCP clients dropped (tunnel down)", label));
    }

    /**
     * Start both the TCP listener and WebSocket server.
     * Blocks until {@link #stop()} is called.
     */
    public void start() throws IOException, InterruptedException {
        // Start WebSocket server in a background thread
        WebSocketServer wss = createWsServer();
        wss.setReuseAddr(true);
        wss.start();

        // Start TCP listener
        try (ServerSocket serverSocket = new ServerSocket()) {
            serverSocket.setReuseAddress(true);
            serverSocket.bind(new InetSocketAddress(tcpHost, tcpPort));
            LOG.info(String.format("[%s] TCP listener on %s:%d (for local Android apps)", label, tcpHost, tcpPort));

            while (running.get()) {
                try {
                    Socket client = serverSocket.accept();
                    executor.submit(() -> handleTcpClient(client));
                } catch (IOException e) {
                    if (running.get()) {
                        LOG.log(Level.WARNING, "[{0}] TCP accept failed: {1}", new Object[]{label, e.getMessage()});
                    }
                }
            }
        } finally {
            wss.stop(1000);
            executor.shutdownNow();
            dropAllTcpClients();
            LOG.info(String.format("[%s] Tunnel stopped", label));
        }
    }

    /** Signal this tunnel to stop. */
    public void stop() {
        running.set(false);
    }

    private static void closeQuietly(Socket s) {
        try { s.close(); } catch (IOException ignored) {}
    }
}