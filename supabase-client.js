/* IMPOSTOR — Supabase multiplayer client */
(() => {
  const cfg = window.IMPOSTOR_SUPABASE;
  if (!cfg || !window.supabase?.createClient) {
    setConnection("BACKEND ERROR");
    console.error("Supabase configuration or client library missing.");
    return;
  }

  const db = window.supabase.createClient(cfg.url, cfg.publishableKey);
  let roomPoll = null;
  let roomId = null;
  let roomRefreshBusy = false;
  let currentState = null;
  let lastSnapshotSignature = null;
  let myReady = false;
  let heartbeatTimer = null;
  let heartbeatBusy = false;

  async function heartbeat() {
    if (!roomId || document.visibilityState !== "visible" || heartbeatBusy) return;
    heartbeatBusy = true;
    try {
      await rpc("impostor_heartbeat", { p_room_id: roomId });
    } catch (e) {
      console.warn("Presence heartbeat:", e.message || e);
    } finally {
      heartbeatBusy = false;
    }
  }

  function startHeartbeat() {
    if (heartbeatTimer) clearInterval(heartbeatTimer);
    heartbeat();
    heartbeatTimer = setInterval(heartbeat, 15000);
  }

  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") heartbeat();
  });

  async function ensureAuth() {
    const { data: { session }, error: sessionError } = await db.auth.getSession();
    if (sessionError) throw sessionError;
    if (session) return session.user;
    const { data, error } = await db.auth.signInAnonymously();
    if (error) throw new Error("Anonymous sign-in is disabled in Supabase. Enable it under Authentication → Sign In / Providers → Anonymous.");
    return data.user;
  }

  async function rpc(name, args = {}) {
    const { data, error } = await db.rpc(name, args);
    if (error) throw error;
    return data;
  }

  function showError(id, error) {
    const message = error?.message || String(error || "Something went wrong.");
    if ($(id)) err(id, message);
    console.error(message);
  }

  function mapPlayers(list) {
    players = Object.fromEntries((list || []).map(p => [p.id, p]));
  }

  function applySnapshot(payload) {
    if (!payload) return;
    roomId = payload.roomId || roomId;
    roomCode = payload.roomCode || roomCode;
    const signature = JSON.stringify([payload.isHost, payload.state, payload.privateInfo]);
    if (signature === lastSnapshotSignature) return;
    lastSnapshotSignature = signature;
    isHost = !!payload.isHost;
    const state = payload.state;
    currentState = state;
    if (state?.phase !== "hints") clearInterval(hostTimer);
    privateInfo = payload.privateInfo || null;
    if (!state) return;
    mapPlayers(state.players);
    game = state.phase === "lobby" ? null : state;
    const me = (state.players || []).find(p => p.id === playerId);
    myReady = !!me?.ready;

    if (state.phase === "lobby") {
      setScreen("lobby");
      $("roomCode").textContent = roomCode;
      renderLobbySettings(state);
      $("playersCount").textContent = state.players.length + " / " + (state.maxPlayers || 8) + " joined";
      $("lobbyPlayers").innerHTML = playerListHTML(state.players);
      $("startBtn").classList.toggle("hidden", !isHost);
      $("startBtn").disabled = state.players.length < 2 || !state.players.every(p => p.ready);
      $("startBtn").textContent = state.players.length < 2 ? "Waiting for players…" : "Start game (" + state.players.length + ")";
      $("readyBtn").textContent = myReady ? "Ready ✓" : "I'm ready";
      $("readyBtn").classList.toggle("primary", myReady);
      $("readyBtn").classList.remove("hidden");
      $("lobbyError").textContent = "";
      return;
    }
    if (state.phase === "hints") {
      setScreen("game");
      renderGameFromState(state, privateInfo);
      if (state.deadline) updateTimer(new Date(state.deadline).getTime());
      return;
    }
    if (state.phase === "vote") {
      setScreen("vote");
      $("voteDescription").textContent = "Vote for the player you think is the impostor.";
      $("voteList").classList.remove("hidden");
      $("confirmVote").classList.remove("hidden");
      renderVote(state);
      $("voteWait").textContent = privateInfo?.hasVoted ? "Vote submitted. Waiting for everyone…" : "";
      return;
    }
    if (state.phase === "judge") {
      if (playerId === state.judgeId) {
        game = state;
        showJudge();
      } else {
        setScreen("vote");
        $("voteDescription").textContent = "The Judge is deciding the tie…";
        $("voteList").innerHTML = "";
        $("confirmVote").classList.add("hidden");
      }
      return;
    }
    if (state.phase === "guess") {
      if (privateInfo?.role === "impostor") setScreen("guess");
      else {
        setScreen("vote");
        $("voteDescription").textContent = "The impostor has one final guess…";
        $("voteList").innerHTML = "";
        $("confirmVote").classList.add("hidden");
      }
      return;
    }
    if (state.phase === "results" && state.result) {
      showResults(state.result);
    }
  }

  async function refreshRoom() {
    if (!roomCode || roomRefreshBusy) return;
    roomRefreshBusy = true;
    try {
      const data = await rpc("impostor_get_room", { p_code: roomCode });
      applySnapshot(data);
    } catch (e) {
      showError("lobbyError", e);
    } finally {
      roomRefreshBusy = false;
    }
  }

  function subscribeRoom() {
    if (roomPoll) clearInterval(roomPoll);
    if (!roomId) return;
    roomPoll = setInterval(refreshRoom, 1200);
  }

  async function enterRoom(payload) {
    applySnapshot(payload);
    subscribeRoom();
    startHeartbeat();
    setConnection("CONNECTED");
    $("joinBtn").disabled = false;
  }

  async function createRoom() {
    name = $("createName").value.trim().slice(0, 16) || "Player";
    serverMaxPlayers = Number($("maxPlayers").value) || 6;
    serverRounds = Number($("roundCount").value) || 5;
    $("startServerBtn").disabled = true;
    err("createError", "");
    try {
      const payload = await rpc("impostor_create_room", {
        p_name: name,
        p_max_players: serverMaxPlayers,
        p_rounds: serverRounds,
        p_visibility: serverVisibility
      });
      playerId = (await db.auth.getUser()).data.user.id;
      await enterRoom(payload);
    } catch (e) {
      showError("createError", e);
      $("startServerBtn").disabled = false;
      setConnection("OFFLINE");
    }
  }

  async function joinRoom() {
    const code = $("joinCode").value.trim().toUpperCase();
    name = $("joinName").value.trim().slice(0, 16) || "Player";
    if (!/^[A-Z0-9]{6}$/.test(code)) {
      err("homeError", "Enter a 6-character room code.");
      return;
    }
    $("joinBtn").disabled = true;
    err("homeError", "");
    setConnection("CONNECTING…");
    try {
      const payload = await rpc("impostor_join_room", { p_code: code, p_name: name });
      playerId = (await db.auth.getUser()).data.user.id;
      await enterRoom(payload);
    } catch (e) {
      showError("homeError", e);
      $("joinBtn").disabled = false;
      setConnection("OFFLINE");
    }
  }

  async function loadServerList() {
    try {
      const rooms = await rpc("impostor_list_public_rooms");
      $("serverList").innerHTML = rooms.length ? rooms.map(r =>
        '<button class="player server-card" data-code="' + esc(r.code) + '" style="width:100%;text-align:left;cursor:pointer">' +
        '<div class="avatar">🎮</div><div class="player-name"><strong>' + esc(r.host || "Player") + '</strong><div class="small">' +
        esc(r.players) + ' / ' + esc(r.maxPlayers) + ' players · ' + esc(r.rounds) + ' rounds</div></div>' +
        '<span class="tag ready">JOIN ↗</span></button>'
      ).join("") : '<div class="empty-servers"><div class="empty-icon">⌕</div><strong>No rooms to show yet</strong><span>Create a public room or try again in a moment.</span></div>';
      $("serverList").querySelectorAll("[data-code]").forEach(button => button.onclick = async () => {
        $("joinCode").value = button.dataset.code;
        $("joinName").value = name || "Player";
        setScreen("codeEntry");
      });
      $("serverBrowserNote").textContent = rooms.length + " public room" + (rooms.length === 1 ? "" : "s") + " available.";
    } catch (e) {
      $("serverBrowserNote").textContent = e.message || "Could not load public rooms.";
    }
  }

  async function quickMatch() {
    name = window.prompt("Choose your player name", "Player")?.trim().slice(0, 16) || "Player";
    setConnection("FINDING GAME…");
    try {
      const payload = await rpc("impostor_quick_match", { p_name: name });
      playerId = (await db.auth.getUser()).data.user.id;
      await enterRoom(payload);
    } catch (e) {
      setConnection("CONNECTED");
      setScreen("servers");
      $("serverBrowserNote").textContent = e.message || "No public rooms available right now.";
      await loadServerList();
    }
  }

  async function setReady() {
    if (!roomId) return;
    try {
      const payload = await rpc("impostor_set_ready", { p_room_id: roomId, p_ready: !myReady });
      applySnapshot(payload);
    } catch (e) { showError("lobbyError", e); }
  }

  async function hostStart() {
    if (!roomId || !isHost) return;
    try { applySnapshot(await rpc("impostor_start_game", { p_room_id: roomId })); }
    catch (e) { showError("lobbyError", e); }
  }

  async function hostSubmitHint(id, text) {
    try { applySnapshot(await rpc("impostor_submit_hint", { p_room_id: roomId, p_hint: text })); }
    catch (e) { showError("lobbyError", e); }
  }

  async function hostVote(id, target) {
    try { applySnapshot(await rpc("impostor_submit_vote", { p_room_id: roomId, p_target: target })); }
    catch (e) { showError("voteError", e); }
  }

  async function hostJudge(id, target) {
    try { applySnapshot(await rpc("impostor_judge_vote", { p_room_id: roomId, p_target: target })); }
    catch (e) { showError("voteError", e); }
  }

  async function hostGuess(id, guess) {
    try { applySnapshot(await rpc("impostor_submit_guess", { p_room_id: roomId, p_guess: guess })); }
    catch (e) { showError("voteError", e); }
  }

  async function advanceIfTimedOut() {
    if (!isHost || !roomId) return;
    try { applySnapshot(await rpc("impostor_advance_timeout", { p_room_id: roomId })); }
    catch (e) { console.warn(e); }
  }

  async function leaveRoom() {
    try { if (roomId) await rpc("impostor_leave_room", { p_room_id: roomId }); }
    catch (e) { console.warn(e); }
    if (roomPoll) clearInterval(roomPoll);
    if (heartbeatTimer) clearInterval(heartbeatTimer);
    location.reload();
  }

  async function rematch() {
    if (!roomId || !isHost) {
      $("backHomeBtn").click();
      return;
    }
    try { applySnapshot(await rpc("impostor_reset_room", { p_room_id: roomId })); }
    catch (e) { showError("lobbyError", e); }
  }

  $("quickMatchBtn").onclick = quickMatch;
  $("findServersBtn").onclick = () => { setScreen("servers"); loadServerList(); };
  $("createServerBtn").onclick = () => setScreen("createServer");
  $("startServerBtn").onclick = createRoom;
  $("joinBtn").onclick = joinRoom;
  $("readyBtn").onclick = setReady;
  $("startBtn").onclick = hostStart;
  $("submitHint").onclick = () => {
    const hint = $("hintInput").value.trim();
    if (!hint) return;
    $("submitHint").disabled = true;
    hostSubmitHint(playerId, hint).finally(() => $("submitHint").disabled = false);
    $("hintInput").value = "";
  };
  $("confirmVote").onclick = () => {
    if (!selectedVote) return;
    $("confirmVote").disabled = true;
    hostVote(playerId, selectedVote);
  };
  $("confirmJudge").onclick = () => {
    if (!selectedJudge) return;
    $("confirmJudge").disabled = true;
    hostJudge(playerId, selectedJudge);
  };
  $("submitGuess").onclick = () => {
    const guess = $("guessInput").value.trim();
    if (guess) hostGuess(playerId, guess);
  };
  $("leaveBtn").onclick = leaveRoom;
  $("rematchBtn").onclick = rematch;
  $("copyCode").onclick = () => navigator.clipboard?.writeText(roomCode);
  $("backHomeBtn").onclick = leaveRoom;

  $("enterCodeBtn").onclick = () => setScreen("codeEntry");
  $("serversBackBtn").onclick = () => setScreen("home");
  $("codeBackBtn").onclick = () => setScreen("servers");
  $("createBackBtn").onclick = () => setScreen("home");

  ensureAuth().then(() => setConnection("CONNECTED")).catch(e => {
    setConnection("AUTH ERROR");
    console.error("Supabase auth:", e);
    $("serverBrowserNote").textContent = e.message || "Could not connect to Supabase.";
  });

  // The legacy timer calls this global function; redirect it to the server-side timer RPC.
  window.advanceIfTimedOut = advanceIfTimedOut;

  // Keep the public directory fresh while it is open.
  setInterval(() => {
    if ($("servers")?.classList.contains("active")) loadServerList();
  }, 8000);
})();
