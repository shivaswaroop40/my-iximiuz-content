// Browser-side bundle: exposes Excalidraw's own scene conversion and export functions.
import {
  convertToExcalidrawElements,
  exportToSvg,
  exportToBlob,
  exportToCanvas,
} from "@excalidraw/excalidraw";

window.excalidrawExport = { convertToExcalidrawElements, exportToSvg, exportToBlob, exportToCanvas };
