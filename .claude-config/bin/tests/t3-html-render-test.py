#!/usr/bin/env python3
"""Check inline script syntax and the example's reduced-motion chart startup.

Run the shipped renderCost function with a small SVG host. The intro's CSS
starts its marks hidden, so reduced motion must skip that class, not just the
animation. Node is already required by the repository's syntax gate.
"""
import json
import re
import subprocess
import unittest
from pathlib import Path

ASSETS = Path(__file__).resolve().parents[3] / "SKILLS/t3-html-render/assets"


def node(source, payload):
    result = subprocess.run(
        ["node", "--input-type=commonjs", "-e", source],
        input=json.dumps(payload), text=True, capture_output=True, timeout=15,
        check=True,
    )
    return json.loads(result.stdout)


class HtmlRender(unittest.TestCase):
    def test_inline_scripts_parse(self):
        for path in sorted(ASSETS.glob("*.html")):
            with self.subTest(page=path.name):
                scripts = re.findall(r"<script>([\s\S]*?)</script>", path.read_text())
                self.assertTrue(scripts, "No inline script found")
                self.assertEqual(node("""
const scripts=JSON.parse(require('node:fs').readFileSync(0,'utf8'));
for(const script of scripts)new (require('node:vm').Script)(script);
console.log(JSON.stringify(scripts.length));
""", scripts), len(scripts))

    def test_chart_intro_respects_motion_and_only_runs_once(self):
        html = (ASSETS / "example-report.html").read_text()
        match = re.search(
            r"(function renderCost\(\)\{[\s\S]*?\n\})\nfunction updateCost", html,
        )
        self.assertIsNotNone(match, "renderCost not found")
        for reduced in (False, True):
            with self.subTest(reduced_motion=reduced):
                result = node("""
const {source,reduced}=JSON.parse(require('node:fs').readFileSync(0,'utf8'));
const classes=[];
const box={clientWidth:344,textContent:''};
const $=()=>box;
const window={matchMedia:query=>{
 if(query!=='(prefers-reduced-motion: reduce)')throw Error('Unexpected media query');
 return {matches:reduced};
}};
const OPT=['A','B','C'].map(k=>({k,c:'#888'}));
let firstCost=true,CR=null;
function el(tag,attrs,parent){
 const names=[];
 if(tag==='svg')classes.push(names);
 return {style:{},classList:{add:name=>names.push(name)},
         addEventListener(){},setAttribute(){}};
}
function updateCost(){}
eval(source+';renderCost();renderCost();');
console.log(JSON.stringify(classes));
""", {"source": match.group(1), "reduced": reduced})
                self.assertEqual(result, [([] if reduced else ["intro"]), []])


if __name__ == "__main__":
    unittest.main()
