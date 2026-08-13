import golden_match as gm
from pathlib import Path
def report(meeting="20260810_094722"):
    anchors, hand, cells = gm.MEETINGS[meeting]
    kind = gm.CELL_KIND_094722
    wrong = {"база": {"лишних":0,"пропущено":0}, "ансамбль": {"лишних":0,"пропущено":0}}
    total = len(anchors)*len(cells); bad = 0
    detail = {}
    for key,(path,_) in cells.items():
        f = gm.found((gm.HERE/path).read_text(encoding="utf-8"), meeting)
        over  = [i for i in anchors if f[i] and not hand[i][key]]
        under = [i for i in anchors if not f[i] and hand[i][key]]
        bad += len(over)+len(under)
        wrong[kind[key]]["лишних"] += len(over); wrong[kind[key]]["пропущено"] += len(under)
        detail[key] = (sum(f.values()), sum(hand[i][key] for i in anchors), over, under)
    print(f"сверка {total-bad}/{total} = {(total-bad)/total*100:.0f} %")
    for k,(m,h,o,u) in detail.items():
        print(f"  {k} ({kind[k]:8}): матчер {m:2} рука {h:2} · лишних {len(o)} {o} · пропущено {len(u)} {u}")
    print(f"  перекос: база лишних {wrong['база']['лишних']} / пропущено {wrong['база']['пропущено']} · "
          f"ансамбль лишних {wrong['ансамбль']['лишних']} / пропущено {wrong['ансамбль']['пропущено']}")
    return (total-bad)/total
if __name__ == "__main__":
    report()
