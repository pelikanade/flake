(function () {
  "use strict";
  var MINUTE = 60, HOUR = 3600, DAY = 86400, MONTH = 30 * DAY;

  function label(seconds) {
    if (seconds < MINUTE) return "just now";
    if (seconds < HOUR) return Math.floor(seconds / MINUTE) + " min ago";
    if (seconds < DAY) return Math.floor(seconds / HOUR) + " h ago";
    if (seconds < MONTH) return Math.floor(seconds / DAY) + " d ago";
    return null;
  }

  function tick() {
    var now = Date.now();
    var nodes = document.querySelectorAll("time[data-ago]");
    for (var i = 0; i < nodes.length; i++) {
      var started = Date.parse(nodes[i].getAttribute("datetime"));
      if (isNaN(started)) continue;
      var text = label((now - started) / 1000);
      if (text !== null) nodes[i].textContent = text;
    }
  }

  tick();
  setInterval(tick, 30000);
})();
