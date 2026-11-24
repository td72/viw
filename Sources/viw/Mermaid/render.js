// Called from MermaidRenderer.swift: draws one diagram into #out at its natural size and
// returns that size, so the caller can cut exactly the diagram out of the page as a PDF.
let diagramCount = 0;

async function renderDiagram(source, theme) {
  const out = document.getElementById('out');
  out.innerHTML = '';
  mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', theme: theme, suppressErrorRendering: true });
  const { svg } = await mermaid.render('viw' + (diagramCount++), source);
  out.innerHTML = svg;
  const el = out.querySelector('svg');
  // mermaid sizes the svg to its container (max-width); pin it to the size of its own drawing.
  const box = el.viewBox.baseVal;
  el.style.maxWidth = 'none';
  el.setAttribute('width', box.width);
  el.setAttribute('height', box.height);
  await document.fonts.ready;
  const rect = el.getBoundingClientRect();
  return { width: rect.width, height: rect.height };
}
