'use strict';
const {validDisplayRequest, selectionFor} = require('./policy.cjs');

// A single in-flight request, explicit selection, and revalidation after the
// chooser prevent a navigated/destroyed frame from acquiring screen access.
class CaptureController {
  constructor({getContents, getSources, choose, platform = process.platform}) {
    Object.assign(this, {getContents, getSources, choose, platform}); this.busy = false;
  }
  async handle(request, callback) {
    let delivered = false;
    const done = value => { if (delivered) return; delivered = true; try { callback(value); } catch {} };
    if (this.busy || !validDisplayRequest(request, this.getContents())) { done(null); return; }
    this.busy = true;
    try {
      const sources = await this.getSources();
      if (!sources.length || !validDisplayRequest(request, this.getContents())) { done(null); return; }
      const selected = await this.choose(sources, request.audioRequested);
      if (!validDisplayRequest(request, this.getContents())) { done(null); return; }
      done(selectionFor(sources, selected, request.audioRequested, this.platform));
    } catch { done(null); }
    finally { this.busy = false; }
  }
}
module.exports = {CaptureController};
