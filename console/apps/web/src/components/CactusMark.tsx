/* 品牌图标：白底黑边圆角框内一颗像素仙人掌（左上受光，右下背光，顶缀像素花）。
   网格：viewBox 32，框内 27px 活区，cell=3 起于 (4, 6.5)。
   主干 2 格宽；双臂自主干侧面水平伸出、仅在肘部向上翘（左肘高、右肘低），肘下无枝。 */
export function CactusMark({ size = 16 }: { size?: number }) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 32 32"
      aria-hidden="true"
      style={{ flex: 'none', display: 'inline-block' }}
    >
      <rect x={1.5} y={1.5} width={29} height={29} rx={7} fill="var(--paper-warm)" stroke="var(--ink)" strokeWidth={2} />
      <g shapeRendering="crispEdges">
        <rect x={14.5} y={3.5} width={3} height={3} fill="var(--amber)" />
        <rect x={13} y={6.5} width={3} height={18} fill="var(--cactus-light)" />
        <rect x={16} y={6.5} width={3} height={3} fill="var(--cactus-light)" />
        <rect x={4} y={9.5} width={3} height={12} fill="var(--cactus-light)" />
        <rect x={7} y={18.5} width={6} height={3} fill="var(--cactus-light)" />
        <rect x={16} y={9.5} width={3} height={15} fill="var(--cactus)" />
        <rect x={13} y={24.5} width={3} height={3} fill="var(--cactus)" />
        <rect x={19} y={21.5} width={6} height={3} fill="var(--cactus)" />
        <rect x={16} y={24.5} width={3} height={3} fill="var(--cactus-dark)" />
        <rect x={25} y={12.5} width={3} height={12} fill="var(--cactus-dark)" />
      </g>
    </svg>
  );
}
