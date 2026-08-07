# Checkout-page privacy boundary

## System and purpose

The desktop shopping extension observes cart, checkout, and completed-order pages so signed-in shoppers can receive cashback and Relvino can attribute purchases to the right retailer.

## Business impact

The proposed release can include visible shipping names, addresses, postal codes, and phone numbers when a shopper grants analytics permission, contrary to the current promise about contact details.
The release is still pending, so no shopper is exposed by this change today.

## Decision requested

Should this release remove order-page snapshots to preserve the current promise, or should the product explicitly authorize narrower collection and revise consent before release?
