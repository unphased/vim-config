/* PaperWM custom JavaScript - tracked in git
 * To apply: cp paperwm-user.js ~/.local/share/gnome-shell/extensions/paperwm@paperwm.github.com/config/user.js
 * Then: Disable and re-enable PaperWM extension in GNOME Extensions app
 * NOTE: user.js is NOT WORKING in GNOME 45+ due to GNOME changes
 */

import * as Tiling from './tiling.js';
import * as Keybindings from './keybindings.js';

/**
 * IMPORTANT: `user.js` is not working in Gnome 45 due to a change in Gnome
 * that stops loading a custom module.  We're investigating potential
 * alternatives, but please be warned that this functionality might no
 * longer be possible in Gnome 45.
 * See https://github.com/paperwm/PaperWM/issues/576#issuecomment-1721315729
 */

export function enable() {
    // Runs when extension is enabled
}

export function disable() {
    // Runs when extension is disabled
}
