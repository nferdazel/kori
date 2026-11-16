// Small DOM helpers. No framework, no virtual DOM: the page builds nodes and replaces blocks.

export function q<T extends Element = HTMLElement>(sel: string, root: ParentNode = document): T | null {
  return root.querySelector<T>(sel);
}

export function qq<T extends Element = HTMLElement>(sel: string, root: ParentNode = document): T[] {
  return Array.from(root.querySelectorAll<T>(sel));
}

export function el<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  cls?: string | null,
  text?: string | null,
): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag);
  if (cls) node.className = cls;
  if (text !== undefined && text !== null) node.textContent = text;
  return node;
}

export function clear(node: Element | null): void {
  if (node) node.replaceChildren();
}

export function show(node: Element | null, visible: boolean): void {
  if (!node) return;
  (node as HTMLElement).hidden = !visible;
}
