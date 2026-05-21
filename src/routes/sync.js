import { runFullSync } from '../sync/scheduler.js';

export function mountSyncRoutes(api, ctx) {
  api.post('/sync', async (req, res) => {
    // Fire and forget; client can poll /api/feeds or /api/episodes for changes.
    runFullSync(ctx).catch(() => {});
    res.json({ ok: true, started: true });
  });

  api.get('/sync/status', (req, res) => {
    const pending = ctx.db.prepare(
      `SELECT COUNT(*) AS n FROM episodes WHERE chapters_status = 'pending'`
    ).get().n;
    const errored = ctx.db.prepare(
      `SELECT COUNT(*) AS n FROM episodes WHERE chapters_status = 'error'`
    ).get().n;
    const lastSync = ctx.db.prepare(
      `SELECT MAX(last_synced_at) AS t FROM feeds`
    ).get().t;
    res.json({ chaptersPending: pending, chaptersErrored: errored, lastFeedSyncAt: lastSync });
  });
}
