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

  async function loadMyProfile() {
    try {
      const profile = await rpc("impostor_my_profile");
      updateHomeProgress(profile.coins, profile.xp, profile.level);
      const stats = $("profileStats");
      if (stats) stats.innerHTML = '<span>🪙 ' + Number(profile.coins || 0).toLocaleString() + '</span><span>LVL ' + Number(profile.level || 1) + '</span><span>' + Number(profile.xp || 0).toLocaleString() + ' XP</span>';
    } catch (e) {
      console.warn("Could not load player profile:", e.message || e);
    }
  }


  const ADJECTIVES = ["Happy","Sleepy","Sneaky","Bouncy","Wobbly","Cheeky","Misty","Lucky","Fuzzy","Cosmic","Tiny","Jolly","Swift","Chill","Goofy","Mellow"];
  const ANIMALS = ["Hippo","Panda","Penguin","Fox","Otter","Koala","Tiger","Frog","Llama","Badger","Dolphin","Hamster","Gecko","Pigeon","Raccoon","Duck"];
  const randomGuestName = () => ADJECTIVES[Math.floor(Math.random()*ADJECTIVES.length)] + ANIMALS[Math.floor(Math.random()*ANIMALS.length)] + (1000+Math.floor(Math.random()*9000));
  let guestName = localStorage.getItem("impostor_guest_name") || randomGuestName();
  localStorage.setItem("impostor_guest_name", guestName);
  let guestAvatar = Number(localStorage.getItem("impostor_guest_pfp"));
  if (!Number.isInteger(guestAvatar) || guestAvatar < 1 || guestAvatar > 8) {
    guestAvatar = 1 + Math.floor(Math.random() * 8);
    localStorage.setItem("impostor_guest_pfp", String(guestAvatar));
  }
  let accountUser = null;
  let modalSubmit = null;
  const avatarPath = id => "assets/pfps/pfp-" + String(id).padStart(2,"0") + ".webp";
  function selectedAvatar() {
    const saved = Number(accountUser?.user_metadata?.avatar_id);
    return Number.isInteger(saved) && saved >= 1 && saved <= 8 ? saved : guestAvatar;
  }
  function displayProfile() {
    const user = accountUser;
    const custom = user && !user.is_anonymous && user.user_metadata?.display_name;
    const shown = custom || guestName;
    window.impostorAvatarId = selectedAvatar();
    if ($("profileDisplayName")) $("profileDisplayName").textContent = shown;
    if ($("profileDescription")) $("profileDescription").textContent = custom ? "Signed-in account · custom username" : "Guest account · progress saved on this device";
    if ($("profileAvatar")) $("profileAvatar").innerHTML = '<img src="' + avatarPath(selectedAvatar()) + '" alt="Profile picture">';
    document.querySelectorAll(".profile-showcase-avatar").forEach(img => { img.src = avatarPath(selectedAvatar()); });
    document.querySelectorAll(".profile-showcase-name").forEach(el => { el.textContent = shown; });
    if ($("signupBtn")) $("signupBtn").classList.toggle("hidden", !!custom);
    if ($("signinBtn")) $("signinBtn").classList.toggle("hidden", !!custom);
    if ($("rerollNameBtn")) $("rerollNameBtn").classList.toggle("hidden", !!custom);
  }
  function customizeAvatar() {
    const current = selectedAvatar();
    const choices = Array.from({length:8},(_,i)=>{
      const id=i+1;
      return '<button type="button" class="avatar-choice'+(id===current?' selected':'')+'" data-avatar-id="'+id+'" aria-label="Choose profile picture '+id+'"><img src="'+avatarPath(id)+'" alt="Profile picture '+id+'"></button>';
    }).join("");
    openModal({kicker:"MAKE IT YOURS",title:"Choose your profile picture",description:"Pick one of the eight avatars.",body:'<div class="avatar-picker">'+choices+'</div>',actions:[{label:"Done",run:closeModal}]});
    $("modalBody").querySelectorAll("[data-avatar-id]").forEach(button=>{
      button.onclick=async()=>{
        const id=Number(button.dataset.avatarId);
        if(accountUser && !accountUser.is_anonymous){
          const {data,error}=await db.auth.updateUser({data:{avatar_id:id}});
          if(error){modalError(error.message);return;}
          accountUser=data.user;
        } else {
          guestAvatar=id;
          localStorage.setItem("impostor_guest_pfp",String(id));
        }
        $("modalBody").querySelectorAll(".avatar-choice").forEach(choice=>choice.classList.toggle("selected",choice===button));
        displayProfile();
      };
    });
  }
  function openModal({title,description="",kicker="IMPOSTOR",body="",actions=[]}) {
    $("modalKicker").textContent=kicker; $("modalTitle").textContent=title;
    $("modalDescription").textContent=description; $("modalBody").innerHTML=body;
    $("modalError").textContent="";
    $("modalActions").innerHTML=actions.map((a,i)=>'<button type="button" class="modal-action '+(a.secondary?'secondary':'')+'" data-modal-action="'+i+'">'+a.label+'</button>').join("");
    $("customModal").classList.remove("hidden");
    actions.forEach((a,i)=>{$("modalActions").querySelector('[data-modal-action="'+i+'"]').onclick=async()=>{if(a.run)await a.run();};});
    $("modalClose").onclick=closeModal;
    $("customModal").onclick=e=>{if(e.target===$("customModal"))closeModal();};
    const first=$("modalBody").querySelector("input"); if(first) setTimeout(()=>first.focus(),30);
  }
  function closeModal(){ $("customModal").classList.add("hidden"); }
  function modalError(message){ $("modalError").textContent=message||"Something went wrong."; }
  function authDialog(mode) {
    const signup=mode==="signup";
    openModal({kicker:"YOUR IMPOSTOR ACCOUNT",title:signup?"Choose a custom name":"Welcome back",description:signup?"Create an account to keep your custom username and progress across devices.":"Sign in to your existing IMPOSTOR account.",
      body:'<div class="modal-field"><label for="authUsername">CUSTOM USERNAME (OPTIONAL WHEN SIGNING IN)</label><input id="authUsername" maxlength="16" minlength="3" placeholder="YourName123" autocomplete="username"></div><div class="modal-field"><label for="authEmail">EMAIL</label><input id="authEmail" type="email" placeholder="you@example.com" autocomplete="email"></div><div class="modal-field"><label for="authPassword">PASSWORD</label><input id="authPassword" type="password" minlength="8" placeholder="At least 8 characters" autocomplete="'+(signup?'new-password':'current-password')+'"></div>',
      actions:[{label:signup?"Create account":"Sign in",run:()=>submitAuth(mode)},{label:"Continue with Google",secondary:true,run:startGoogleAuth},{label:"Cancel",secondary:true,run:closeModal}]});
  }
  async function startGoogleAuth() {
    const buttons=$("modalActions").querySelectorAll("button");
    buttons.forEach(b=>b.disabled=true);
    try {
      const user=accountUser || (await db.auth.getUser()).data.user;
      const options={redirectTo:window.location.origin+window.location.pathname};
      // Keep the current guest's progress by linking Google to its anonymous account.
      const result=user?.is_anonymous
        ? await db.auth.linkIdentity({provider:"google",options})
        : await db.auth.signInWithOAuth({provider:"google",options});
      if(result.error) throw result.error;
    } catch(e) {
      modalError(e.message||"Could not start Google sign-in.");
      buttons.forEach(b=>b.disabled=false);
    }
  }

  async function submitAuth(mode) {
    const username=$("authUsername").value.trim();
    const email=$("authEmail").value.trim();
    const password=$("authPassword").value;
    if(mode==="signup"&&(username.length<3||username.length>16||!/^[a-zA-Z0-9_ ]+$/.test(username))){modalError("Username must be 3–16 characters (letters, numbers, spaces or _).");return;}
    if(!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)){modalError("Enter a valid email address.");return;}
    if(password.length<8){modalError("Your password must be at least 8 characters.");return;}
    const buttons=$("modalActions").querySelectorAll("button");buttons.forEach(b=>b.disabled=true);
    try {
      if(mode==="signup"){
        const {data,error}=await db.auth.updateUser({email,password,data:{display_name:username}});
        if(error)throw error;
        accountUser=data.user; displayProfile();
        modalError("Account details saved. Check your email if confirmation is required, then sign in with these details.");
        $("modalTitle").textContent="Check your email";
        $("modalDescription").textContent="Your guest profile is being upgraded. Confirm your email if Supabase asks you to.";
        $("modalBody").innerHTML="";
        $("modalActions").innerHTML='<button class="modal-action" id="modalDone" type="button">Got it</button>';
        $("modalDone").onclick=closeModal;
      } else {
        const {data,error}=await db.auth.signInWithPassword({email,password});
        if(error)throw error;
        accountUser=data.user;
        if(username){
          const {error:metaError}=await db.auth.updateUser({data:{display_name:username}});
          if(metaError)throw metaError;
        }
        accountUser=(await db.auth.getUser()).data.user;
        displayProfile(); await loadMyProfile(); closeModal();
      }
    } catch(e) { modalError(e.message||"Could not complete account action."); buttons.forEach(b=>b.disabled=false); }
  }

  async function ensureAuth() {
    const { data: { session }, error: sessionError } = await db.auth.getSession();
    if (sessionError) throw sessionError;
    if (session) { accountUser=session.user; return session.user; }
    const { data, error } = await db.auth.signInAnonymously();
    if (error) throw new Error("Anonymous sign-in is disabled in Supabase. Enable it under Authentication → Sign In / Providers → Anonymous.");
    accountUser=data.user; return data.user;
  }

  async function rpc(name, args = {}, signal = null) {
    let request = db.rpc(name, args);
    if (signal && typeof request.abortSignal === "function") request = request.abortSignal(signal);
    const { data, error } = await request;
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


  function updateHomeProgress(coins=0, xp=0, level=1) {
    const coinNode = $("homeCoins"), levelNode = $("homeLevel");
    const xpText = $("homeXpText"), xpFill = $("homeXpFill");
    const currentLevel = Math.max(1, Number(level) || 1);
    const totalXp = Math.max(0, Number(xp) || 0);
    const start = (currentLevel - 1) ** 2 * 100;
    const next = currentLevel ** 2 * 100;
    const earned = Math.max(0, totalXp - start);
    const needed = Math.max(100, next - start);
    if (coinNode) coinNode.textContent = Number(coins || 0).toLocaleString();
    if (levelNode) levelNode.textContent = currentLevel;
    if (xpText) xpText.textContent = earned.toLocaleString() + " / " + needed.toLocaleString();
    if (xpFill) xpFill.style.width = Math.min(100, earned / needed * 100) + "%";
  }

  let lastKnownLevel = null;

  function renderProgress(playerList) {
    const me = (playerList || []).find(p => p.id === playerId);
    if (!me) return;
    updateHomeProgress(me.coins, me.xp, me.level);
    const stats = $("profileStats");
    if (stats) stats.innerHTML = '<span>🪙 ' + Number(me.coins || 0).toLocaleString() + '</span><span>LVL ' + Number(me.level || 1) + '</span><span>' + Number(me.xp || 0).toLocaleString() + ' XP</span>';
    if (lastKnownLevel !== null && Number(me.level || 1) > lastKnownLevel) {
      const summary = $("rewardSummary");
      if (summary) summary.dataset.levelup = "true";
    }
    lastKnownLevel = Number(me.level || 1);
  }

  function renderMatchRewards(result) {
    const box = $("rewardSummary");
    if (!box || !result) return;
    const role = privateInfo?.role || "crew";
    const won = (result.winner === "crew" && role === "crew") ||
                (result.winner === "impostor" && role === "impostor");
    const coins = won ? (role === "impostor" ? 60 : 25) : 0;
    const xp = won ? (role === "impostor" ? 160 : 100) : 15;
    const me = Object.values(players).find(p => p.id === playerId);
    const level = Number(me?.level || 1);
    box.innerHTML =
      '<div class="reward-earned"><strong>+' + coins + ' 🪙</strong><span>+' + xp + ' XP</span></div>' +
      '<div class="reward-caption">' + (won ? "Victory rewards" : "Participation XP") +
      ' · Level ' + level + (box.dataset.levelup === "true" ? ' · LEVEL UP!' : '') + '</div>';
    box.dataset.levelup = "false";
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
    renderProgress(state.players);
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
      renderMatchRewards(state.result);
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
    name = accountUser && !accountUser.is_anonymous && accountUser.user_metadata?.display_name || guestName;
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
    name = accountUser && !accountUser.is_anonymous && accountUser.user_metadata?.display_name || guestName;
    if (!/^[A-Z0-9]{6}$/.test(code)) {
      err("homeError", "Enter a 6-character room code.");
      return;
    }

    const button = $("joinBtn");
    button.disabled = true;
    err("homeError", "Connecting to the room…");
    setConnection("CONNECTING…");

    let expired = false;
    let timeoutId;
    const attempt = (async () => {
      // Auth can hang too, so the timeout covers sign-in, user lookup AND the room RPC.
      const user = await ensureAuth();
      if (expired) return;
      const { data: userData, error: userError } = await db.auth.getUser();
      if (expired) return;
      if (userError || !userData?.user) throw userError || new Error("Your player session could not be loaded.");
      const payload = await rpc("impostor_join_room", { p_code: code, p_name: name });
      if (expired) return;
      if (!payload?.state || !payload?.roomId) throw new Error("The server returned an invalid room response.");
      playerId = userData.user.id;
      if (payload.isHost && (payload.state.players || []).length === 1) {
        throw new Error("This browser/account is already hosting this room. Join from another browser profile or device.");
      }
      lastSnapshotSignature = null;
      await enterRoom(payload);
      err("homeError", "");
    })();

    try {
      await Promise.race([
        attempt,
        new Promise((_, reject) => {
          timeoutId = setTimeout(() => {
            expired = true;
            reject(new Error("Connection timed out. Supabase sign-in or the room server did not respond. Check your connection and try again."));
          }, 12000);
        })
      ]);
    } catch (e) {
      expired = true;
      const message = e?.message || "Could not join this room.";
      err("homeError", message);
      console.error("Join room failed:", e);
      button.disabled = false;
      setConnection("OFFLINE");
    } finally {
      clearTimeout(timeoutId);
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
        setScreen("codeEntry");
      });
      $("serverBrowserNote").textContent = rooms.length + " public room" + (rooms.length === 1 ? "" : "s") + " available.";
    } catch (e) {
      $("serverBrowserNote").textContent = e.message || "Could not load public rooms.";
    }
  }

  async function quickMatch() {
    name = accountUser && !accountUser.is_anonymous && accountUser.user_metadata?.display_name || guestName;
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
  $("rerollNameBtn").onclick = () => { guestName=randomGuestName(); localStorage.setItem("impostor_guest_name",guestName); displayProfile(); };
  $("customizeAvatarBtn").onclick = customizeAvatar;
  $("signupBtn").onclick = () => authDialog("signup");
  $("signinBtn").onclick = () => authDialog("signin");
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

  ensureAuth().then(async () => {
    accountUser=(await db.auth.getUser()).data.user;
    displayProfile();
    setConnection("CONNECTED");
    await loadMyProfile();
  }).catch(e => {
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
