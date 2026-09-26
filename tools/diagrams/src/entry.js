// Browser-side bundle: exposes Excalidraw's own scene conversion and export functions.
import {
  convertToExcalidrawElements,
  exportToSvg,
  exportToBlob,
} from "@excalidraw/excalidraw";

window.excalidrawExport = { convertToExcalidrawElements, exportToSvg, exportToBlob };
