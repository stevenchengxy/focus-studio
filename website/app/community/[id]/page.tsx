import { CommunityDetail } from '@/components/community/detail';
export const metadata={title:'A community creation · Focus Studio'};
export default async function Page({params}:{params:Promise<{id:string}>}){const{id}=await params;return <CommunityDetail id={id}/>;}
