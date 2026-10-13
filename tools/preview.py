import sys, os, colorsys; sys.path.insert(0, os.path.dirname(__file__)); import dts, dts_mesh
import matplotlib; matplotlib.use('Agg'); import matplotlib.pyplot as plt
from mpl_toolkits.mplot3d.art3d import Poly3DCollection
def preview(path, out, state=0):
    objs=dts.read_file(open(path,'rb').read())
    shape=objs[0]; anim=[e for e in shape['extra'] if e['type']=='an_anim_list'][0]
    P=dts_mesh.posed_polys(shape, anim, state)
    polys=[p[3] for p in P]; cols=[colorsys.hsv_to_rgb((p[0]*0.13)%1,0.6,0.95) for p in P]
    fig=plt.figure(figsize=(15,5))
    for k,(el,az) in enumerate([(5,-90),(5,0),(25,-60)]):
        ax=fig.add_subplot(1,3,k+1,projection='3d')
        ax.add_collection3d(Poly3DCollection(polys,facecolors=cols,edgecolors='k',linewidths=0.2))
        r=shape['radius']; c=shape['center']
        ax.set_xlim(c[0]-r,c[0]+r);ax.set_ylim(c[1]-r,c[1]+r);ax.set_zlim(c[2]-r,c[2]+r); ax.view_init(el,az)
        ax.set_xlabel('x');ax.set_ylabel('y')
    plt.tight_layout(); plt.savefig(out,dpi=70)
if __name__=='__main__': preview(sys.argv[1], sys.argv[2])
