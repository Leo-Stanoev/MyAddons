# VendorCost

A lightweight World of Warcraft addon that displays the NPC vendor buy price of items directly in their tooltips. Never get scammed on the Auction House for an item you could buy from a vendor for a few copper.

## Features
* **Tooltip Injection:** Cleanly displays the exact vendor cost in your item tooltips using native Blizzard coin icons.
* **Live Merchant Scanning:** Silently scans and records prices whenever you open a merchant window, building a highly accurate live database as you play.
* **Bulk Purchase Tracking:** Automatically calculates the "per item" cost and shows a clear `x1` tag if a vendor sells the item in stacks.
* **Custom Positioning:** Choose exactly where the vendor cost line appears in the tooltip via the options menu.

## Usage
The addon works automatically in the background. You can customize it using the following chat commands:

* `/vc` - Opens the VendorCost options panel.
* `/vc on` | `/vc off` - Quickly toggle the tooltip additions on or off.
* `/vc scan` - Forces a manual scan of the currently open merchant.
* `/vc debug` - Prints database statistics to your chat window.