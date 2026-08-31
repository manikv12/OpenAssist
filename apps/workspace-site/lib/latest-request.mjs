/** Keep slow UI reads from replacing a newer or already-closed item. */
export class LatestRequestGate {
  constructor() {
    this.revision = 0;
  }

  begin() {
    this.revision += 1;
    return this.revision;
  }

  cancel() {
    this.revision += 1;
  }

  isCurrent(requestId) {
    return requestId === this.revision;
  }
}
