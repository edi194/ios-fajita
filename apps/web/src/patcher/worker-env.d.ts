// FileReaderSync exists only in workers; the DOM lib does not declare it.
declare class FileReaderSync {
  readAsArrayBuffer(blob: Blob): ArrayBuffer;
}
declare module "*.wasm?url" {
  const url: string;
  export default url;
}

// OPFS synchronous access (workers only), missing from the DOM lib of this TypeScript.
interface FileSystemSyncAccessHandle {
  read(buffer: ArrayBufferView, options?: { at?: number }): number;
  write(buffer: ArrayBufferView, options?: { at?: number }): number;
  truncate(size: number): void;
  getSize(): number;
  flush(): void;
  close(): void;
}
interface FileSystemFileHandle {
  createSyncAccessHandle(): Promise<FileSystemSyncAccessHandle>;
}
