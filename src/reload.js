(() => {
  const revision = document.currentScript.dataset.revision;
  const events = new EventSource("/__zmd/events");
  events.onmessage = (event) => {
    if (event.data !== revision) {
      events.close();
      window.location.reload();
    }
  };
})();
