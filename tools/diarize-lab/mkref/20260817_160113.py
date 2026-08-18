import json
# Таймкоды реплик системного стема; текст в репозиторий не уехал
# (живые встречи). Как получены — DIARIZATION.md, раздел «Эталон».
utts=json.load(open("utts/20260817_160113.sys.utts.json"))
# индекс реплики -> кто. P — ведущая встречу продюсерка (доминирующий голос),
# O — любой другой человек с той стороны, '?' — по тексту не решается.
lab={}
def put(a,b,v):
    for i in range(a,b+1): lab[i]=v
put(0,7,'P'); put(8,11,'?'); put(12,14,'O'); put(15,16,'P'); put(17,18,'?')
put(19,23,'O'); put(24,26,'?'); put(27,29,'O'); put(30,30,'?'); put(31,34,'O')
put(35,36,'?'); put(37,38,'O'); put(39,40,'?'); put(41,42,'O'); put(43,44,'?')
put(45,46,'O'); put(47,48,'?'); put(49,54,'O'); put(55,56,'?'); put(57,57,'P')
put(58,67,'?'); put(68,111,'P'); put(112,113,'?'); put(114,141,'P')
put(142,155,'?'); put(156,177,'P'); put(178,181,'?'); put(182,224,'P')
put(225,225,'?'); put(226,249,'P'); put(250,250,'?'); put(251,254,'P')
put(255,256,'?'); put(257,302,'P'); put(303,303,'?'); put(304,331,'P')
put(332,337,'O'); put(338,341,'P'); put(342,343,'O'); put(344,346,'?')
put(347,349,'P')
spans=[]
for i,u in enumerate(utts):
    v=lab.get(i,'?')
    if v=='?': continue
    spans.append({"speaker":v,"start":u['start'],"end":u['end']})
spans.sort(key=lambda s:s['start'])
merged=[]
for s in spans:
    if merged and merged[-1]['speaker']==s['speaker'] and s['start']-merged[-1]['end']<0.05:
        merged[-1]['end']=max(merged[-1]['end'],s['end'])
    else: merged.append(dict(s))
json.dump(merged,open("ref/20260817_160113.sys.ref.json","w"),ensure_ascii=False,indent=1)
tot=sum(u['end']-u['start'] for u in utts)
sc=sum(s['end']-s['start'] for s in merged)
byp={}
for s in merged: byp[s['speaker']]=byp.get(s['speaker'],0)+s['end']-s['start']
print(f"вся дальняя речь {tot:.0f} с; размечено {sc:.0f} с ({sc/tot*100:.0f} %)")
print({k:round(v) for k,v in byp.items()})
