// Tucks the two giant numerals behind the portrait: reads the cutout's alpha in the numerals' band and puts
// the left numeral's right edge, and the right numeral's left edge, `tuck` px inside the silhouette.
// Svelte action on the hero element; expects .giant.l, .giant.r and an <img data-subject>.

export function hug(node: HTMLElement, tuck = 0.07) {
  let raf = 0;
  const place = () => {
    const img = node.querySelector<HTMLImageElement>("img[data-subject]");
    const l = node.querySelector<HTMLElement>(".giant.l");
    const r = node.querySelector<HTMLElement>(".giant.r");
    if (!img || !l || !r || !img.complete || !img.naturalWidth) return;
    const hb = node.getBoundingClientRect();
    const ib = img.getBoundingClientRect();
    const c = document.createElement("canvas");
    // measure at a reduced scale: plenty for an outline
    const scale = Math.min(1, 320 / ib.width);
    c.width = Math.max(1, Math.round(ib.width * scale));
    c.height = Math.max(1, Math.round(ib.height * scale));
    const x = c.getContext("2d", { willReadFrequently: true });
    if (!x) return;
    // object-fit: contain, anchored at the bottom
    const s = Math.min(c.width / img.naturalWidth, c.height / img.naturalHeight);
    const w = img.naturalWidth * s;
    const h = img.naturalHeight * s;
    x.drawImage(img, (c.width - w) / 2, c.height - h, w, h);
    const a = x.getImageData(0, 0, c.width, c.height).data;
    l.style.left = "0px";
    const lb = l.getBoundingClientRect();
    const y0 = Math.max(0, Math.floor((lb.top + lb.height * 0.2 - ib.top) * scale));
    const y1 = Math.min(c.height, Math.ceil((lb.bottom - lb.height * 0.1 - ib.top) * scale));
    let minX = c.width;
    let maxX = -1;
    for (let y = y0; y < y1; y += 2)
      for (let xx = 0; xx < c.width; xx++)
        if (a[(y * c.width + xx) * 4 + 3] > 128) {
          if (xx < minX) minX = xx;
          if (xx > maxX) maxX = xx;
        }
    if (maxX < 0) return;
    const inset = ib.width * tuck;
    const left = ib.left - hb.left + minX / scale;
    const right = ib.left - hb.left + maxX / scale;
    l.style.left = `${left + inset - lb.width}px`;
    r.style.left = `${right - inset}px`;
    node.classList.add("hugged");
  };
  const schedule = () => {
    cancelAnimationFrame(raf);
    raf = requestAnimationFrame(place);
  };
  const img = node.querySelector<HTMLImageElement>("img[data-subject]");
  img?.addEventListener("load", schedule);
  document.fonts?.ready.then(schedule);
  const ro = new ResizeObserver(schedule);
  ro.observe(node);
  schedule();
  return {
    destroy() {
      cancelAnimationFrame(raf);
      ro.disconnect();
      img?.removeEventListener("load", schedule);
    },
  };
}
