import Foundation

/// Nested scrollers must also be at their edge. Embedded documents and
/// scroll chaining blocked by CSS are unknown/consumed, so never navigate.
enum HistorySwipeEdgeScript {
    static func source(x: Double, y: Double) -> String {
        """
        (() => {
          let node = document.elementFromPoint(innerWidth * \(x), innerHeight * \(y));
          let back = true, forward = true;
          if (!node) return {back: false, forward: false};
          while (node) {
            if (/^(IFRAME|FRAME|OBJECT|EMBED)$/.test(node.tagName) || node.tagName.includes('-'))
              return {back: false, forward: false};
            const style = getComputedStyle(node);
            if (style.overscrollBehaviorX === 'none' || style.overscrollBehaviorX === 'contain')
              return {back: false, forward: false};
            const range = node.scrollWidth - node.clientWidth;
            if (range > 1 && (node === document.scrollingElement || /^(auto|scroll|overlay)$/.test(style.overflowX))) {
              const min = style.direction === 'rtl' ? -range : 0;
              const max = style.direction === 'rtl' ? 0 : range;
              back = back && node.scrollLeft <= min + 1;
              forward = forward && node.scrollLeft >= max - 1;
            }
            node = node.parentElement;
          }
          return {back, forward};
        })()
        """
    }
}
