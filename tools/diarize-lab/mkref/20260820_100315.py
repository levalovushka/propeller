import json
# Таймкоды реплик системного стема; текст в репозиторий не уехал
# (живые встречи). Окно первой AX-трассы (сдвиг 24,2 с), разметка владельца
# 2026-08-20 ПО ПАМЯТИ в день встречи, без прослушивания, — точность ниже
# обычной, спорное оставлено '?'. Как получены utts — DIARIZATION.md.
utts=json.load(open("utts/20260820_100315.sys.utts.json"))
# ARINA / LIZA — двое с дальней стороны; '?' — владелец не вспомнил.
lab={}
def put(a,b,v):
    for i in range(a,b+1): lab[i]=v
put(0,2,'?');
put(3,13,'LIZA');
put(14,20,'ARINA');
put(21,22,'?');
put(23,23,'LIZA');
put(24,26,'ARINA');
put(27,29,'?');
put(30,30,'ARINA')
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
json.dump(merged,open("ref/20260820_100315.sys.ref.json","w"),ensure_ascii=False,indent=1)
tot=sum(u['end']-u['start'] for u in utts)
sc=sum(s['end']-s['start'] for s in merged)
byp={}
for s in merged: byp[s['speaker']]=byp.get(s['speaker'],0)+s['end']-s['start']
print(f"дальняя речь окна {tot:.0f} с; размечено {sc:.0f} с ({sc/tot*100:.0f} %)")
print({k:round(v) for k,v in byp.items()})
