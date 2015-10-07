using Microsoft.Owin;
using Owin;

[assembly: OwinStartupAttribute(typeof(Wap2013U5.Startup))]
namespace Wap2013U5
{
    public partial class Startup
    {
        public void Configuration(IAppBuilder app)
        {
            ConfigureAuth(app);
        }
    }
}
