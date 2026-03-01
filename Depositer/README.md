# Depositer

A World of Warcraft (TBC Classic) addon that automates your inventory and bank management. Stop dragging stacks manually and start using intelligent, server-safe algorithms to deposit, compress, and perfectly organize your vault.

## Features
* **Smart & Forced Depositing:** Instantly deposit items from your bags to your bank. By default, it only deposits items that already exist in your bank (perfect for restocking). You can also toggle "Force Deposit" for highly granular sub-categories (e.g., Leather, Herbs, Spell Reagents, Consumables) to automatically sweep farmed materials into your vault.
* **Physical Stack Compressor:** Click once to merge all partial item stacks across both your bags and your bank. Uses a server-safe pacing queue to ensure items are never dropped.
* **Live-Polling Bank Sorter:** Completely bypasses Blizzard's native (and often bugged) sorting. It maps your bank and physically sorts items by `Type > Subtype > Quality > Name`. It safely ignores bag slots and prevents infinite swap loops.
* **Scroll-Wheel StackSplitter:** Replaces the clunky native splitting menu. Hover over a stack, use your mouse wheel to select the amount, and click OK. The addon intelligently auto-drops the split stack into the Trade Window, Mailbox, Bank, or an empty bag slot depending on what you have open.
* **Customizable Ignore List:** Hover over an item in your bags and use a custom keybind (e.g., Middle-Click + Shift) to permanently blacklist it. Ignored items will never be deposited or compressed, and receive a custom "Depositer - Ignored" tooltip tag.

## Requirements
* **None:** Depositer works flawlessly out of the box with the default Blizzard UI, and features dynamic hooking to support popular third-party bag addons like Baggins, Bagnon, and ArkInventory.

## Usage
* Open your Bank window and use the new **Deposit**, **Compress**, and **Sort** buttons located at the top right.
* **Ctrl-Right-Click** any of the three bank buttons to open the comprehensive Options Panel.
* **Middle-Click + Shift** (Customizable in settings) on any item in your bags to add or remove it from your safe-listed Ignore List. 
* Customize the Tooltip padding in the settings so the "Ignored" tag never overlaps with your other addons (like Auctionator or GearScore).