import json
# Таймкоды реплик системного стема; текст в репозиторий не уехал
# (живые встречи). Как получены — DIARIZATION.md, раздел «Эталон».
utts=json.load(open("utts/20260817_165425.sys.utts.json"))
lab={}
def put(a,b,v):
    for i in range(a,b+1): lab[i]=v
# ILYA — тот, кто ведёт презентацию; TONYA — бренд-лид ГПН (женский голос);
# ALEX — «раз я ворвался» (мужской, руководитель); IRA — женский голос HR;
# YURI — единственная реплика по имени. '?' — по тексту не решается.
put(18,34,'ILYA'); put(44,98,'ILYA'); put(100,101,'ILYA'); put(102,214,'ILYA')
put(218,224,'ILYA'); put(231,233,'ILYA'); put(239,239,'ILYA'); put(242,242,'ILYA')
put(234,238,'YURI')
put(240,241,'TONYA'); put(244,349,'TONYA'); put(356,401,'TONYA')
put(627,649,'TONYA'); put(665,678,'TONYA')
put(402,517,'ALEX'); put(527,531,'ALEX'); put(545,583,'ALEX'); put(591,594,'ALEX')
put(602,604,'ALEX'); put(650,664,'ALEX'); put(679,706,'ALEX'); put(708,738,'ALEX')
put(519,526,'IRA'); put(584,590,'IRA'); put(739,749,'IRA'); put(755,758,'IRA')
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
json.dump(merged,open("ref/20260817_165425.sys.ref.json","w"),ensure_ascii=False,indent=1)
tot=sum(u['end']-u['start'] for u in utts); sc=sum(s['end']-s['start'] for s in merged)
byp={}
for s in merged: byp[s['speaker']]=byp.get(s['speaker'],0)+s['end']-s['start']
print(f"вся дальняя речь {tot:.0f} с; размечено {sc:.0f} с ({sc/tot*100:.0f} %)")
print({k:round(v) for k,v in sorted(byp.items(),key=lambda kv:-kv[1])})
