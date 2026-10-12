-- RV Checkpoint+ settings. Edit and restart the game.
-- Key names: https://docs.ue4ss.com/lua-api/table-definitions/key.html (F1..F12, NUM_ZERO, etc.)
return {
    keys = {
        quick_save      = "F5",   -- save RV damage, items and position right now (host)
        quick_load      = "F9",   -- go back to your last quick save (host)
        checkpoint_menu = "F8",   -- pick an earlier checkpoint; F8 again = next, F9 = go (host)
        unstuck_player  = "F6",   -- put yourself next to the RV  (Shift+F6: every player)
        recover_rv      = "F7",   -- RV flipped / stuck / fell through: put it back on its wheels (host)
    },

    -- Save automatically a few seconds after the RV is repaired, so a checkpoint reload
    -- no longer throws your repairs away.
    autosave_after_repair = true,

    -- Quick save automatically every N minutes while driving (0 = off).
    autosave_minutes = 0,

    -- How long on-screen messages stay, in seconds.
    message_seconds = 3.0,

    -- Allow F7 (recover RV). Turn off if you want the vanilla "reload checkpoint" penalty.
    allow_recover_rv = true,
}
