/** Local-only recovery journal. Media is never sent to the account/export API. */
export interface PendingExport {
  blob: Blob;
  exportId: string;
  name: string;
  accountId?: string;
  confirmed?: boolean;
  reservationKey?: string;
}
export interface ExportReservationJob {
  idempotencyKey: string;
  projectId: string;
  accountId?: string;
}
const database = "focus-studio-local-exports";
async function transaction<T>(key:string,operation:"get"|"put"|"delete",value?:unknown):Promise<T> {
  if(typeof indexedDB==="undefined")throw new Error("Local export recovery is unavailable. Enable local storage before exporting.");
  return new Promise((resolve,reject)=>{
    const open=indexedDB.open(database,1);
    open.onupgradeneeded=()=>{if(!open.result.objectStoreNames.contains("exports"))open.result.createObjectStore("exports");};
    open.onerror=()=>reject(new Error("Local export recovery could not be opened. Check local storage and retry."));
    open.onblocked=()=>reject(new Error("Close other Focus Studio windows and try again."));
    open.onsuccess=()=>{
      const db=open.result;const tx=db.transaction("exports",operation==="get"?"readonly":"readwrite");const store=tx.objectStore("exports");
      const request=operation==="get"?store.get(key):operation==="put"?store.put(value,key):store.delete(key);
      let result:T;request.onsuccess=()=>{result=request.result as T;};
      tx.oncomplete=()=>{db.close();resolve(result);};
      tx.onerror=tx.onabort=()=>{db.close();reject(new Error("Local export recovery could not be updated. Free up local storage and retry."));};
    };
  });
}
export function readPendingExport(){return transaction<PendingExport|undefined>("pending","get");}
export function savePendingExport(value:PendingExport){return transaction<void>("pending","put",value);}
export function removePendingExport(){return transaction<void>("pending","delete");}
export function readReservationJob(){return transaction<ExportReservationJob|undefined>("reservation","get");}
export function saveReservationJob(value:ExportReservationJob){return transaction<void>("reservation","put",value);}
export function removeReservationJob(){return transaction<void>("reservation","delete");}
