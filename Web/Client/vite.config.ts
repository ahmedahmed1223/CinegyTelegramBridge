/// <reference types="vitest/config" />
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// The app is served by CinegyBridge.Web from its wwwroot, so the build lands
// there. In development, Vite serves the app and forwards /api to the server.
export default defineConfig({
  plugins: [react()],
  build: {
    outDir: '../Server/wwwroot',
    emptyOutDir: true,
    sourcemap: false,
    // Nothing inlined as data: URLs - the server's CSP allows fonts and
    // scripts from 'self' only, and a small font subset inlined by size
    // was being blocked.
    assetsInlineLimit: 0,
    // Mantine is most of this, and it is one app behind a login: a single
    // cached bundle beats a waterfall of chunks on the station's link.
    chunkSizeWarningLimit: 900,
  },
  server: {
    port: 5173,
    proxy: {
      '/api': { target: 'http://localhost:8790', changeOrigin: false },
    },
  },
  test: {
    environment: 'jsdom',
    // Fork workers can stall when the Windows release checks open the test pool.
    pool: 'vmThreads',
    setupFiles: ['./src/test/setup.ts'],
    css: false,
  },
})
