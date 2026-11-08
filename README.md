# ElriJunk

Automatic junk selling and persistent item marks for **World of Warcraft 3.3.5a**.

ElriJunk sells grey items and items marked for sale when you open a merchant, then reports the proceeds in chat. You can also mark unwanted items for deletion with confirmation.

## Features

- Automatically sells grey items with a vendor price.
- Sells marked items regardless of quality.
- Displays a coin or cross on marked items in your bags.
- Remembers marks for future drops of the same item.
- Supports the default bags and ArkInventory 3.02.
- Requires no additional libraries.

## Installation

1. Copy the `ElriJunk` folder to `World of Warcraft\Interface\AddOns\`.
2. Restart the game completely if this is your first installation.
3. Enable ElriJunk in the AddOns menu on the character selection screen.

To update, replace the addon files and run `/reload`. Your saved marks will be kept.

## Usage

**Ctrl + right-click** an item in your bags to cycle through its marks:

**Unmarked → Coin → Cross → Unmarked.**

| Mark | Action |
| --- | --- |
| None | Normal behavior. Grey items are sold automatically. |
| Coin | Sold when you open a merchant, regardless of quality. |
| Cross | Deleted after confirmation. The item is not sold. |

Items that cannot be sold skip the coin mark: **Unmarked → Cross → Unmarked**. They can be marked for deletion just like other items. Changing marks does not print messages in chat.

Marks are account-wide and stored by `itemID`. They apply to every copy of an item, including future drops. Random suffixes and enchantments sharing the same `itemID` use the same mark.

### Selling

Open a merchant to start selling. The addon sells in batches of up to 12 stacks, waits for each batch to complete, and reports the number of items sold and the proceeds. Wait for the summary before buying, repairing, or selling manually: proceeds are calculated from changes to your money.

Closing the merchant stops the queue. Automatic selling does not start during combat or in repair mode.

### Deleting

The addon checks for items marked with a cross once per second. Automatic confirmation waits 20 seconds after the first marked item arrives, giving you time to loot nearby enemies. Additional items join the batch without restarting the timer. The confirmation stays hidden while a loot window is open. Use `/ej clean` to open it immediately after looting.

The compact confirmation shows the quantity, item list, and vendor value. Opening or closing bags is not required. If there are more than six stacks, the first six are listed along with the number of remaining stacks.

**Deletion is permanent.** Each batch requires confirmation. Cancel or Escape leaves the items in your bags and pauses reminders for ten seconds. The addon then checks again, even if the inventory has not changed. Marks remain after deletion.

Before deleting each stack, the addon checks its slot, item link, quantity, and current mark. Changed or locked stacks are skipped. Newly acquired items are not added to an already confirmed batch.

Deletion is paused during combat, while dead, at a merchant, bank, mailbox, trade window, or auction house, and whenever the cursor is occupied. Locked stacks wait for a later check while unlocked stacks can still be confirmed. Automatic reminders wait for other confirmation dialogs and held modifier keys to clear. If a deletion attempt fails, another confirmation can appear after five seconds. Use `/ej clean` to request confirmation immediately without waiting for a reminder.

## Commands

| Command | Description |
| --- | --- |
| `/ej` | Show help. |
| `/ej version` | Show the addon version currently loaded in the game. Alias: `/ej ver`. |
| `/ej status` | Show the loaded version, saved rule counts, marked item counts, and the current reason deletion is waiting. |
| `/ej clean` | Request confirmation to delete items marked with a cross. |
| `/ej list` | List saved marks. |
| `/ej unmark 12345` | Remove the mark for an `itemID`, even if the item is not in your bags. |

You can use `/elrijunk` instead of `/ej`.

The version command reports the running Lua code. After replacing addon files, run `/reload` to load the update.

## Compatibility and Saved Settings

- Original **3.3.5a** client, interface version `30300`.
- Processes carried bags `0–4`. Bank contents, mail, keyring items, and equipped items are excluded.
- Marks are stored in `WTF\Account\<account>\SavedVariables\ElriJunk.lua`.
- WoW saves settings when you log out or run `/reload`. Recent changes may be lost if the client crashes.
